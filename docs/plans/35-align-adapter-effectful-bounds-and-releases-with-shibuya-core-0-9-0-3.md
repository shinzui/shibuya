---
id: 35
slug: align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3
title: "Align adapter effectful bounds and releases with shibuya-core 0.9.0.3"
kind: exec-plan
created_at: 2026-09-16T23:04:43Z
intention: intention_01m2ycc3fxedxtw5339e0efzy1
master_plan: "docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T23:04:43Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T03:15:22Z
      mode: "update"
      note: "Align adapter verification with shibuya-core 0.9.0.2 and inherit the active intention"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T03:19:36Z
      mode: "update"
      note: "Correct the adapter verification target to the post-EP-2 patch 0.9.0.3"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T13:46:21Z
      mode: "update"
      note: "Target core release moves to provisional 0.9.0.4; title and file name kept for stable identity"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-21T06:00:00Z
      mode: "implement"
      note: "Completed source bounds, dual-family tests, explicit rejection, and the combined solve; adapter publications remain coordinated with the lifecycle candidate version."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-22T17:29:05Z
      mode: "update"
      note: "Milestones 1-3 complete: adapters published in the 0.10 lifecycle cohort"
---

# Align adapter effectful bounds and releases with shibuya-core 0.9.0.3

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, an application that depends on shibuya-core together with the pgmq, Kafka,
and kiroku adapters can be built on either the effectful 2.6 family or the effectful 2.7
family, and no combination of those packages can resolve to `effectful-core` 2.7.0.0 or
2.7.1.0, the two releases whose changelog records a per-operation overhead regression for
dynamically dispatched effects (fixed in 2.7.1.1). Today the three adapters disagree: the pgmq
adapter forbids 2.7 outright, the Kafka adapter allows the regressed versions, and the kiroku
adapter forbids 2.7 and is additionally held back by its own store library. The visible
result is a `cabal build --dry-run` on a scratch project that succeeds with
`--constraint='effectful-core==2.6.1.0'`, succeeds with `--constraint='effectful-core==2.7.1.2'`,
and is rejected by the solver with `--constraint='effectful-core==2.7.1.0'`.

The bound expression is owned by
`docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`
and is copied here verbatim; if that plan changes it, change it here in the same way.

The target core release is 0.9.0.4, provisionally: plan 33 shipped the urgent master-loop fix
alone as 0.9.0.2, the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md
shipped an urgent supervisor-link fix alone as 0.9.0.3 on 2026-09-20, and plan 34 owns the
following patch release containing the shared dependency bounds and benchmark policy that this
adapter work consumes. This plan's title and file name still say 0.9.0.3; they are kept so that
its identity and existing references stay stable, and this paragraph states the current target.
All three adapters' existing bounds on shibuya-core already admit 0.9.0.3, so that release
required no adapter change.

**Status (2026-09-22): Complete.** The adapter bounds did not ship as the patch releases
described below. They shipped in the lifecycle release cohort alongside shibuya-core 0.10.0.0:
shibuya-pgmq-adapter 0.16.1.0, shibuya-kafka-adapter 0.9.1.0, kiroku-store 0.8.0.2, and
shibuya-kiroku-adapter 0.5.1.3, all published on 2026-09-22 and all carrying the range below.
The range is now owned by docs/adr/0005-exclude-regressed-effectful-core-releases-in-every-package.md.
The version numbers in Plan of Work and Concrete Steps are the original, superseded targets.


## Progress

- [x] (2026-09-22 UTC) Milestone 1: shibuya-pgmq-adapter source and dual-family tests complete at `9247388`; published as 0.16.1.0 (tag `v0.16.1.0`) in the lifecycle cohort instead of patch 0.16.0.1.
- [x] (2026-09-22 UTC) Milestone 2: shibuya-kafka-adapter source and dual-family tests complete at `1c455b5`; published as 0.9.1.0 (tag `v0.9.1.0`) in the lifecycle cohort instead of patch 0.9.0.2.
- [x] (2026-09-22 UTC) Milestone 3: kiroku-store and shibuya-kiroku-adapter source and dual-family tests complete at `0dcd092` plus `f91bb05`; published as kiroku-store 0.8.0.2 and shibuya-kiroku-adapter 0.5.1.3 in the lifecycle cohort.
- [x] (2026-09-21 UTC) Milestone 4: combined local-source solve accepts effectful-core 2.6.1.0 and 2.7.1.2 and rejects 2.7.1.0 at kiroku-store's bound.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-09-21: Kiroku's initial widening removed the transitive `<2.7` blocker in both
  `kiroku-store` and `shibuya-kiroku-adapter`, but the broad `>=2.6 && <2.8` range also admitted
  the two releases this plan exists to exclude. A follow-up applies the cohort's disjoint range
  to every store/adapter component and adds a direct `effectful-core` constraint to the adapter
  test stanza, whose umbrella `effectful` dependency alone could not express the exclusion.

- 2026-09-21: The PGMQ example's `effectful ^>=2.6.1.0` constraints meant “2.6 only” and
  prevented its first 2.7.1.2 solve even though every direct core bound was correct. Widening
  the umbrella package to `>=2.6.1 && <2.8` while retaining the direct disjoint core constraint
  produces the intended two-family solve.


## Decision Log

- Decision: Use one bound expression in every package, `effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)`, and `effectful >=2.6.1 && <2.8` wherever a package depends on the umbrella `effectful` package.
  Rationale: The regression is in `effectful-core`, and `effectful` 2.7.1.0 pins `effectful-core >=2.7.1.0 && <2.7.2.0`, which spans both the regressed 2.7.1.0 and the fixed 2.7.1.1. Only a bound on `effectful-core` itself can exclude the regressed release, so every package that has a direct `effectful-core` dependency carries it, and packages that only depend on `effectful` gain a direct `effectful-core` dependency for the bound. The disjunction keeps the 2.6 family available so consumers are not forced to upgrade.
  Date: 2026-09-16

- Decision: Publish the adapter bounds in the lifecycle cohort rather than as standalone patches.
  Rationale: The same adapter repositories had to take the breaking shibuya-core 0.10.0.0
  candidate immediately afterwards. Patches first would have cost consumers two pin bumps and
  forced a new candidate. The bound commits were already tested and could not be affected by
  the version number.
  Date: 2026-09-21

- Decision: Release each adapter as a patch bump. (Superseded 2026-09-21 by the cohort decision above.)
  Rationale: A bound change with no source change is a patch under the PVP, and shibuya-core did the same for 0.9.0.1.
  Date: 2026-09-16

- Decision: Do not release the kiroku adapter from this plan if kiroku-store still forbids effectful 2.7; record the blocker instead.
  Rationale: The kiroku repository releases its packages as a cohort through its own release skill, and widening the adapter's bound while kiroku-store's `effectful-core >=2.4 && <2.7` still forbids 2.7 would advertise a build the solver cannot deliver.
  Date: 2026-09-16


## Outcomes & Retrospective

**Complete (2026-09-22).** All three adapters and kiroku-store were published in the lifecycle
cohort certified by docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md. Each
released cabal file carries the disjoint `effectful-core` range in every component, together
with a `shibuya-core` 0.10 bound. They are minor rather than patch releases because the same
releases include lifecycle fixes and the new core major bound. The kiroku adapter is 0.5.1.3
rather than the planned 0.5.1.2 because of a packaging fix reviewed in REV-18. Milestone 4's
combined local-source solve (below) remains the proof of the accepted and rejected families.
The cohort's unified solver plan is recorded in docs/audits/lifecycle-release/release-verdict.md.

History (2026-09-21):

The version-neutral compatibility work is complete. PGMQ commit `9247388`, Kafka commit
`1c455b5`, and Kiroku commits `0dcd092` plus `f91bb05` apply the safe Effectful ranges across
their current library, test, example, benchmark, and lifecycle-fixture components. Kafka and
PGMQ pass their full live-service adapter suites under effectful-core 2.7.1.2. Kiroku's adapter
and 42-module store suites pass under 2.7.1.2. Formatting, package checks, and all three flake
checks pass; Kafka's distributable default Nix package also builds.

A single local-source project containing Shibuya Core, all three adapters, kiroku-store, and
the Kiroku support packages accepts effectful-core 2.6.1.0 and 2.7.1.2. Its 2.7.1.0 solve is
rejected by `kiroku-store => effectful-core>=2.6.1 && <2.7 || >=2.7.1.1 && <2.8`, proving the
cohort cannot silently select the regressed release.

No package was tagged or published. The three publication milestones remain open because the
same repositories must next admit the breaking Shibuya lifecycle candidate; issuing separate
patch releases immediately before that coordinated candidate requires the release owner's
version decision.


## Context and Orientation

shibuya is a queue-processing framework whose core package, `shibuya-core`, lives in this
repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. Queue-specific adapters
live in their own repositories. This plan touches three of them. Each is registered in Mori,
the local dependency registry; `mori registry show <name> --full` prints its path and packages.

`shinzui/shibuya-pgmq-adapter` is at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`
and contains three packages: the library `shibuya-pgmq-adapter`, the benchmark
`shibuya-pgmq-adapter-bench`, and the example `shibuya-pgmq-example`. It is at version 0.16.0.0,
released on 2026-09-16 under the annotated tag `v0.16.0.0`. Its library depends on the
`pgmq-core`, `pgmq-effectful`, and `pgmq-hasql` packages at `^>=0.6`; the 0.6.1.0 release of
that family (2026-09-16) declares `effectful-core ^>=2.6 || ^>=2.7`, so nothing below the
adapter blocks effectful 2.7. Its own bounds are the blocker:
`shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` line 45 declares `effectful-core ^>=2.6.1.0`
in the library and line 109 declares an unbounded `effectful-core` in the test suite;
`shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal` lines 85 and 129 declare
`effectful-core ^>=2.6`; `shibuya-pgmq-example/shibuya-pgmq-example.cabal` declares
`effectful-core ^>=2.6` at line 49 and both `effectful ^>=2.6.1.0` and `effectful-core ^>=2.6`
at lines 74 to 75 and 101 to 102. The changelog is `shibuya-pgmq-adapter/CHANGELOG.md`, newest
section first, with the heading format `## 0.16.0.0 — 2026-09-16`. The repository's `Justfile`
provides `just build`, `just test`, `just bench`, and `just fmt`; `just process-up` starts the
PostgreSQL instance the tests need. The ambient compiler on the development machine is not the
one the package requires, so every cabal command in that repository must run inside the flake
shell: `nix develop -c cabal ...` (recorded in that repository's plan 7). Releases follow
`agents/skills/release/SKILL.md` in that repository.

`shinzui/shibuya-kafka-adapter` is at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`
with the library `shibuya-kafka-adapter`, the benchmark `shibuya-kafka-adapter-bench`, and the
examples `shibuya-kafka-adapter-jitsurei`. It is at 0.9.0.1 (tag `v0.9.0.1`, 2026-09-15), the
release that raised its bound to effectful-core 2.7. `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`
line 64 declares `effectful-core >=2.6.1 && <2.8` in the library, which admits the regressed
versions, and line 115 declares an unbounded `effectful-core` in the test suite;
`shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal` line 42 declares an
unbounded `effectful-core`. Its `kafka-effectful ^>=0.3.1.0` dependency already builds on
effectful-core 2.7 (the 0.9.0.1 release was built against 2.7.1.2). Its tests need a Kafka
broker at `127.0.0.1:9092`; the `Justfile` recipes `just process-up` and `just create-topics`
prepare it and `just test` runs the suite. Releases follow `agents/skills/release/SKILL.md`
in that repository.

`shinzui/kiroku` is at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. It hosts the
event-store library `kiroku-store` and, among other packages, `shibuya-kiroku-adapter` at
version 0.5.1.1 (tag `shibuya-kiroku-adapter-v0.5.1.1`, 2026-08-16).
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` line 50 declares
`effectful-core >=2.5 && <2.7` in the library and line 74 declares `effectful >=2.4 && <2.7` in
the test suite. `kiroku-store/kiroku-store.cabal` declares `effectful-core >=2.4 && <2.7` at
lines 76 and 151 and both `effectful` and `effectful-core` at `>=2.4 && <2.7` at lines 233 to
234, so the adapter cannot reach effectful 2.7 until kiroku-store does. Kiroku releases each
package independently with its own tag through `agents/skills/release/SKILL.md` in that
repository.

Two terms. A *bound* is the version range a package declares for a dependency in its `.cabal`
file; cabal's solver refuses any plan that violates a bound, so bounds are the only protection a
published package can offer its consumers against a bad dependency version. The PVP is the
Haskell Package Versioning Policy: in a version `A.B.C.D`, `A.B` changes for breaking API
changes, `C` for compatible additions, and `D` for everything else, including bound changes.

The regression being excluded is documented in the effectful-core changelog: 2.7.0.0 "increased
the per-operation overhead of dynamically dispatched effects" and 2.7.1.1 "fix[ed] a performance
regression introduced in 2.7.0.0". The pgmq adapter's `Pgmq` effect and the Kafka adapter's
`KafkaConsumer` effect are dynamically dispatched, so every queue operation they perform is on
that path. The pgmq-hs 0.6.1.0 changelog reached the same conclusion and recommends 2.7.1.1 or
newer; this plan turns that recommendation into bounds.

No ADR exists for any of these repositories; none has a `docs/adr/` directory and Mori lists no
ADR bundle for them.


## Plan of Work

### Milestone 1: pgmq adapter

Widen the pgmq adapter so it admits effectful-core 2.7.1.1 and later while still forbidding
2.7.0.x and 2.7.1.0. In `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` replace line 45's
`effectful-core ^>=2.6.1.0,` with `effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8),`
and give the test suite's bare `effectful-core,` at line 109 the same range. In the bench and
example cabal files replace every `effectful-core ^>=2.6` with the same expression and every
`effectful ^>=2.6.1.0` with `effectful >=2.6.1 && <2.8`. Bump the library version to 0.16.0.1
and add a changelog section above 0.16.0.0 that says the adapter now builds on effectful 2.7
and why 2.7.0.0 through 2.7.1.0 are excluded.

Build and test twice, once per family, so both ends of the disjunction are exercised. Then
release 0.16.0.1 with the repository's release skill. At the end of this milestone `cabal
build --dry-run` inside that repository succeeds under `--constraint='effectful-core==2.6.1.0'`
and under `--constraint='effectful-core==2.7.1.2'`, the test suite passes under the 2.7
constraint, and the tag `v0.16.0.1` exists.

### Milestone 2: Kafka adapter

Tighten the Kafka adapter. In `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` replace line
64's `effectful-core >=2.6.1 && <2.8,` with the disjunction and give the test suite's bare
`effectful-core,` at line 115 the same range; do the same for the examples package at line 42.
Bump to 0.9.0.2, add the changelog section, run the suite against the broker, and release. At
the end, `cabal build --dry-run` in that repository is rejected under
`--constraint='effectful-core==2.7.1.0'` and succeeds under 2.6.1.0 and 2.7.1.2.

### Milestone 3: kiroku adapter

Check whether kiroku-store has lifted its `<2.7` bound. If it has, widen
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` lines 50 and 74 to the disjunction (and
`effectful >=2.6.1 && <2.8` for the test suite's `effectful` line), bump to 0.5.1.2, add the
changelog section, run `just test` in the kiroku repository, and release the adapter through
kiroku's release skill. If it has not, do not edit the adapter; instead record in this plan's
Surprises & Discoveries the kiroku-store lines that block it and the exact edit to make once a
kiroku-store release admits 2.7, and mark this milestone complete as "blocked, recorded" so the
MasterPlan can track it.

### Milestone 4: combined-solve proof

Prove the cohort resolves together. In a scratch directory outside any repository, create a
one-file cabal project that depends on `shibuya-core`, `shibuya-pgmq-adapter`, and
`shibuya-kafka-adapter` at the versions released above, then run three dry-run solves. Record
the three transcripts in this plan.


## Concrete Steps

### Milestone 1 steps

Working directory: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.

Edit the four cabal files as described. The library stanza should read:

```text
    effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8),
```

Add to `shibuya-pgmq-adapter/CHANGELOG.md` above the 0.16.0.0 section:

```markdown
## 0.16.0.1 — <date>

### Other Changes

- The library, test suite, benchmark, and example now accept `effectful-core` 2.7.1.1 and
  later in addition to the 2.6 family, so applications that follow `shibuya-core` 0.9.0.1 to
  effectful 2.7 can build this adapter alongside it. `effectful-core` 2.7.0.0 through 2.7.1.0
  are excluded: those releases carry a per-operation overhead regression for dynamically
  dispatched effects (fixed upstream in 2.7.1.1), and every `Pgmq` operation this adapter
  performs is dynamically dispatched. No source changed.
```

Verify both families:

```bash
nix develop -c cabal build --dry-run all --constraint='effectful-core==2.6.1.0'
nix develop -c cabal build --dry-run all --constraint='effectful-core==2.7.1.2'
nix develop -c cabal build --dry-run all --constraint='effectful-core==2.7.1.0'
```

Expected: the first two print a build plan and exit 0; the third fails in the solver with a
message naming `shibuya-pgmq-adapter` and the rejected `effectful-core-2.7.1.0`. Then, with
PostgreSQL running (`just process-up` in another terminal):

```bash
nix develop -c cabal test --enable-tests all --constraint='effectful-core==2.7.1.2'
```

Expected: the suite reports `0 failures`. Format with `just fmt`, commit with a Conventional
Commits message such as `build(deps): accept effectful-core 2.7.1.1 and later`, carrying the
trailers `MasterPlan: docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md`
and `ExecPlan: docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md`
(both paths are in the shibuya repository, which is where this plan lives), and run that
repository's release skill for a patch release.

### Milestone 2 steps

Working directory: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

Edit the two cabal files as described, bump `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`
to 0.9.0.2, and add to `shibuya-kafka-adapter/CHANGELOG.md`:

```markdown
## 0.9.0.2 — <date>

### Other Changes

- `effectful-core` 2.7.0.0 through 2.7.1.0 are now excluded from the library, test suite, and
  examples. 0.9.0.1 widened the bound to `<2.8`, which admitted those releases; they carry a
  per-operation overhead regression for dynamically dispatched effects (fixed upstream in
  2.7.1.1), and every `KafkaConsumer` operation this adapter performs is dynamically dispatched.
  The 2.6 family remains accepted. No source changed.
```

Run the same three dry-run solves as Milestone 1 (the working directory changes; the commands
do not), then with the broker prepared by `just process-up` and `just create-topics`:

```bash
just test
```

Expected: all tests pass. Format, commit with the two trailers, and release a patch through
that repository's release skill.

### Milestone 3 steps

Working directory: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

```bash
grep -n 'effectful' kiroku-store/kiroku-store.cabal
```

If every line still says `<2.7`, record the blocker and stop this milestone. Otherwise edit
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` lines 50 and 74 as described, bump to
0.5.1.2, add a changelog section in the style of the existing `## 0.5.1.1 — 2026-08-16`
heading, run `just test`, and release with `agents/skills/release/SKILL.md` in that repository
(patch level, package `shibuya-kiroku-adapter`).

### Milestone 4 steps

Working directory: a fresh scratch directory, for example `/tmp/shibuya-solve`.

```bash
mkdir -p /tmp/shibuya-solve && cd /tmp/shibuya-solve
cat > shibuya-solve.cabal <<'CABAL'
cabal-version: 3.0
name:          shibuya-solve
version:       0
build-type:    Simple

library
  build-depends:
    base,
    shibuya-core ^>=0.9.0.4,
    shibuya-pgmq-adapter ^>=0.16.0.1,
    shibuya-kafka-adapter ^>=0.9.0.2
CABAL
cabal update
cabal build --dry-run --constraint='effectful-core==2.6.1.0'
cabal build --dry-run --constraint='effectful-core==2.7.1.2'
cabal build --dry-run --constraint='effectful-core==2.7.1.0'
```

Expected: the first two commands print a plan; the third ends with a solver rejection that
names at least one of the three packages and `effectful-core-2.7.1.0`. Paste the three tails
into this plan under Outcomes & Retrospective. If shibuya-core 0.9.0.4 is not yet on Hackage,
substitute `^>=0.9.0.3`, which is published, and note it.


## Validation and Acceptance

Milestone 1 is accepted when, in the pgmq adapter repository, both family constraints solve,
the 2.7.1.0 constraint is rejected, the test suite passes under the 2.7.1.2 constraint, and the
tag `v0.16.0.1` exists. Milestone 2 is accepted on the same three-solve pattern plus a passing
suite and the tag `v0.9.0.2`. Milestone 3 is accepted either by a passing suite and the tag
`shibuya-kiroku-adapter-v0.5.1.2` or by a recorded blocker naming the kiroku-store lines.
Milestone 4 is accepted when the three transcripts are recorded in this plan.


## Idempotence and Recovery

Every edit is a text change under version control and can be re-applied or reverted with git.
The dry-run solves make no changes. If a release step fails after the tag is pushed, follow the
repository's release skill for its retry rules; do not delete a pushed tag.


## Interfaces and Dependencies

No Haskell source changes. The only interface this plan defines is the bound expression,
which must read exactly:

```text
effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
```

and, where a package depends on the umbrella package:

```text
effectful >=2.6.1 && <2.8
```

Both are owned by `docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`.


## Revision Notes

2026-09-20 UTC: Retargeted adapter verification from the provisional combined 0.9.1.0
release to shibuya-core 0.9.0.3. Plan 33 now ships the urgent runtime fix alone as 0.9.0.2;
plan 34 owns the following dependency-bound patch.

2026-09-20 UTC: Moved the target core release from 0.9.0.3 to the provisional 0.9.0.4, because 0.9.0.3 was published by the standalone supervisor-link fix in docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md and plan 34's dependency-bound release now follows it. The title, file name and earlier revision notes keep 0.9.0.3 for stable identity and as history.

2026-09-21 UTC: Completed all source, solver, test, package, and flake compatibility gates for
the three adapters and closed the former kiroku-store blocker. Publications remain deliberately
open and are coordinated with EP-44's candidate version; no tag or upload is claimed.

2026-09-22 UTC: Marked Milestones 1 through 3 and the plan complete. The adapters were published in
the 0.10 lifecycle cohort (pgmq 0.16.1.0, Kafka 0.9.1.0, kiroku-store 0.8.0.2, kiroku adapter
0.5.1.3), not as the patches originally planned. Recorded the release-vehicle decision and
pointed to ADR 0005. The title and file name keep "0.9.0.3" for stable identity.
