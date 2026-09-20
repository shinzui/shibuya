---
id: 34
slug: harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7
title: "Harden shibuya-core dependency bounds and release gating for effectful 2.7"
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
      note: "Defer bound hardening to the release after EP-1 and inherit the active intention"
---

# Harden shibuya-core dependency bounds and release gating for effectful 2.7

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

shibuya-core 0.9.0.1 raised its `effectful` upper bound from `<2.7` to `<2.8` so that downstream
packages could move to effectful 2.7. The bound it chose, `effectful >=2.6.1 && <2.8`, admits
`effectful-core` 2.7.0.0 and 2.7.1.0, the two releases whose own changelog says they "increased
the per-operation overhead of dynamically dispatched effects" (fixed in 2.7.1.1 on 2026-08-24).
Nothing in shibuya-core is dynamically dispatched, so the core itself is not the victim, but
every adapter's queue effect is, and a consumer whose solver or freeze file lands on those two
versions today gets no warning from any bound in the cohort. The same release went out as a
patch, and the repository's release skill skips its benchmark regression gate for patches, so
the cohort's first dependency-family swap on the hot path was never measured.

After this plan, a `cabal build --dry-run` of shibuya-core is rejected under
`--constraint='effectful-core==2.7.1.0'` and accepted under both `2.6.1.0` and `2.7.1.2`; the
release skill states that any release which changes the admitted versions of a runtime
dependency runs the benchmark gate whatever its PVP level, and shows how to compare two
dependency versions on one tree; and this plan holds the measured comparison of effectful
2.6.1 against 2.7.1 that the 0.9.0.1 release should have carried. The result of that
measurement, recorded below, is that effectful 2.7.1 is at parity or better on every leaf, and
roughly twice as fast on the `Async` hot path.

Plan 33 ships its urgent runtime fix alone as 0.9.0.2. This plan therefore owns the following
core/metrics patch release, provisionally 0.9.0.3, after the bound, benchmark-policy, and
evidence milestones are complete. Recheck Hackage and upstream tags before release; if another
version is published first, use the next free patch and synchronize the parent and consumers.


## Progress

- [ ] Milestone 1: `effectful-core` exclusion bound in shibuya-core, shibuya-example, and shibuya-core-bench; three dry-run solves recorded.
- [ ] Milestone 2: release skill gates runtime-dependency changes on the benchmark regardless of bump level and documents the one-tree comparison procedure.
- [ ] Milestone 3: benchmark evidence for the 0.9.0.1 swap recorded in this plan, including the 2.7.1.0 measurement.
- [ ] Milestone 4: release shibuya-core and shibuya-metrics with the hardened bounds, provisionally as 0.9.0.3.


## Surprises & Discoveries

- 2026-09-16 (during the review that produced this plan): the shibuya-core benchmark suite
  was built twice from the same tree, once with `--constraint='effectful==2.6.1.0'` and once
  with the tree's normal solve (effectful 2.7.1.0, effectful-core 2.7.1.2), and a 27-leaf hot
  path subset was run with `--stdev 5 --timeout 120` on an Apple Silicon development machine
  under GHC 9.12.4. tasty-bench's own comparison reported `same as baseline` for every
  framework leaf except three: `framework-overhead.processing.runWithMetrics-100` at 23% slower
  (53.5 to 65.9 microseconds, a leaf so short that its pure-streamly sibling also moved 10%
  with no effectful involvement, so this is noise), `handler-overhead.io-handler.counter-10000`
  at 8% faster, and `hot-path.async8-noop-10000` at 55% faster. Allocation on every shibuya
  leaf was 3 to 5% lower under 2.7.1.

  ```text
  leaf                                                       2.6.1        2.7.1     delta   alloc 2.6.1 -> 2.7.1
  framework-overhead.processing.runWithMetrics-1000        526.0 us     564.4 us    +7.3%    2.43 MB -> 2.30 MB
  framework-overhead.processing.runWithMetrics-10000      5812.7 us    5650.0 us    -2.8%   24.53 MB -> 23.25 MB
  framework-overhead.comparison.10000-msgs.shibuya        7127.2 us    7159.8 us    +0.5%   34.26 MB -> 32.97 MB
  handler-overhead.noop-handler.10000-msgs                6721.5 us    6952.0 us    +3.4%   32.41 MB -> 31.12 MB
  handler-overhead.io-handler.counter-10000               7362.1 us    6733.5 us    -8.5%   33.36 MB -> 32.08 MB
  concurrency-modes.cpu-bound-serial.10000-msgs           6527.5 us    6307.1 us    -3.4%   31.20 MB -> 29.93 MB
  concurrency-levels.ahead-100msgs-1ms.ahead-20           3723.7 us    3865.6 us    +3.8%    2.51 MB -> 2.51 MB
  concurrency-levels.async-100msgs-1ms.async-20           3189.4 us    3214.3 us    +0.8%    2.05 MB -> 2.02 MB
  hot-path.serial-noop-10000                             10723.7 us   10609.0 us    -1.1%   22.09 MB -> 20.77 MB
  hot-path.async8-noop-10000                            124861.4 us   55607.4 us   -55.5%   49.76 MB -> 40.85 MB
  ```

  The `async8` result was suspicious enough to re-run: two further alternating runs of the
  `hot-path` leaves gave 120 ms and 124 ms under 2.6.1 against 53.5 ms and 54.8 ms under 2.7.1,
  with 47 MB against 39 MB allocated, so the improvement is real. The likely cause is in the
  effectful-core 2.7.0.0 changelog: unlifting functions created with the `ConcUnlift Persistent`
  strategy "now correctly share the effect storage" and their thread registration "no longer
  leaks a finalizer". shibuya's `processUntilDrained` in
  `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` creates exactly such an unlift and
  streamly's worker threads call it once per message, so a cheaper registration lands on the
  `Async` path. This is a plausible attribution, not a proven one.

- 2026-09-16: the same subset was then run on a third build pinned to
  `effectful-core==2.7.1.0`, the regressed release the bound is meant to exclude, against the
  same 2.6.1 baseline. Every serial leaf was `same as baseline` (for example
  `runWithMetrics-10000` 5812.7 to 5613.6 microseconds, `noop-handler.10000-msgs` 6721.5 to
  6687.6, `hot-path.serial-noop-10000` 10723.7 to 10361.1), `async8-noop-10000` was again 53%
  faster (58.1 ms), and the four `async-100msgs-1ms` leaves, which timed out once at the 120
  second limit, converged on a re-run with `--timeout 300` at 3.82, 2.90, 2.92, and 3.27 ms
  against 4.17, 3.32, 3.54, and 3.61 ms for a 2.6.1 re-run in the same session. So on
  shibuya-core's own benchmark, 2.7.1.0 is indistinguishable from 2.7.1.2. That is the expected
  result, not a contradiction of the upstream changelog: the regression it describes is in
  dynamically dispatched effects, and nothing the shibuya-core suite exercises is dynamically
  dispatched. The exclusion therefore rests on the upstream changelog and on the adapters'
  queue effects being dynamic, not on a shibuya-core measurement; if a measurement is wanted,
  it has to come from an adapter benchmark (for example the pgmq adapter's
  `shibuya-pgmq-adapter-bench` built against 2.7.1.0 and 2.7.1.1), which is optional and
  outside this plan.


## Decision Log

- Decision: Replace the `effectful` dependency with `effectful-core` in shibuya-core,
  shibuya-example, and shibuya-core-bench rather than adding `effectful-core` beside it.
  Rationale: The only modules any of those packages import are `Effectful` and
  `Effectful.Dispatch.Static`, both of which live in `effectful-core` and are merely re-exported
  by `effectful`. The exclusion has to be stated on `effectful-core`, because `effectful`
  2.7.1.0 pins `effectful-core >=2.7.1.0 && <2.7.2.0`, a range that contains both the regressed
  2.7.1.0 and the fixed 2.7.1.1. Keeping `effectful` as well would leave a direct dependency
  whose only purpose is a bound that belongs on the package that provides the modules. The
  pgmq and Kafka adapters already depend on `effectful-core` alone. A consumer that imports
  effectful's IO-effect modules must already declare `effectful` itself, so nothing is taken
  from anyone.
  Date: 2026-09-16

- Decision: The bound is `effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)`.
  Rationale: Keep the 2.6 family so consumers are not forced to move; exclude exactly the
  releases the upstream changelog names; stop at `<2.8` as 0.9.0.1 did.
  Date: 2026-09-16

- Decision: The benchmark gate in the release skill is keyed on what changed, not only on the
  bump level: any release whose diff changes the admitted versions of `effectful-core`,
  `effectful`, `streamly`, `streamly-core`, `nqe`, `stm`, or an `hs-opentelemetry-*` package
  runs the gate, and the comparison is made on one tree with the old and new versions pinned
  through `--constraint` and separate `--builddir`s.
  Rationale: A worktree of the last tag resolves to the same dependency versions as the current
  tree unless a bound changed, so the existing "baseline from the previous tag" procedure
  measures nothing for a bound-only release. Pinning both versions on the same source isolates
  the dependency's effect.
  Date: 2026-09-16

- Decision: No Haskell source change is required.
  Rationale: The measurements show effectful 2.7.1 is at parity or better; the hazard is what
  the bounds admit, not what was shipped.
  Date: 2026-09-16

- Decision: Cut the dependency-bound work as the patch release after 0.9.0.2, provisionally
  0.9.0.3.
  Rationale: Plan 33's crash fix is ready while this plan has not started. Shipping 0.9.0.2
  immediately avoids holding a runtime fix for independent dependency-policy work; this plan's
  updated release gate then applies to its own bound-changing patch.
  Date: 2026-09-20 UTC


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

shibuya is a supervised queue-processing framework built on the `effectful` effect system. This
repository, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, contains four packages
listed in `cabal.project`: `shibuya-core` (the library), `shibuya-metrics` (a metrics web
server), `shibuya-example` (two example executables), and `shibuya-core-bench` (a tasty-bench
benchmark suite plus two stress executables; not released). `cabal.project.local` enables
tests and benchmarks. The current release is 0.9.0.1, tagged `v0.9.0.1` on 2026-09-15, and the
last build on this machine resolved effectful 2.7.1.0 with effectful-core 2.7.1.2 (see
`dist-newstyle/cache/plan.json`).

Two terms. A *bound* is the version range a package's `.cabal` file declares for a dependency;
cabal's solver refuses any plan that violates it, so bounds are the only protection a published
package can give its consumers against a bad dependency version. *Dynamic dispatch* is
effectful's mechanism for effects whose handler is chosen at run time (the `Pgmq` and
`KafkaConsumer` effects the adapters use); shibuya-core's own `Tracing` effect in
`shibuya-core/src/Shibuya/Telemetry/Effect.hs` is *statically* dispatched, which is why the
core is not itself exposed to the 2.7.0.0 regression.

The dependency lines to change:

`shibuya-core/shibuya-core.cabal` line 75 `effectful >=2.6.1 && <2.8,` in the library
`build-depends`, and line 140 `effectful,` in the test suite.
`shibuya-example/shibuya-example.cabal` lines 34 and 65, `effectful >=2.6.1 && <2.8,` in the
two executables. `shibuya-core-bench/shibuya-core-bench.cabal` lines 53, 87, and 125,
`effectful >=2.6 && <2.8,` in the benchmark and the two executables. `shibuya-metrics` has no
effectful dependency. The only effectful modules imported anywhere in these packages are
`Effectful` (36 imports) and `Effectful.Dispatch.Static` (2 imports), verified with
`grep -rhoE '^import Effectful[A-Za-z.]*' shibuya-core shibuya-example shibuya-core-bench`.

The effectful-core changelog, readable through Mori at
`/Users/shinzui/Keikaku/hub/haskell/effectful-project/effectful/effectful-core/CHANGELOG.md`
(`mori registry show effectful/effectful --full` prints the path), says for 2.7.1.1: "Fix a
performance regression introduced in 2.7.0.0 that increased the per-operation overhead of
dynamically dispatched effects." The `effectful` umbrella package at 2.7.1.0 declares
`effectful-core >=2.7.1.0 && <2.7.2.0` in its cabal file. The pgmq-hs 0.6.1.0 changelog
(2026-09-16) recommends effectful-core 2.7.1.1 or newer for the same reason but chose a
recommendation over a bound; this plan chooses the bound because shibuya is the root of a
cohort of adapters whose effects are all dynamically dispatched.

The release skill is `agents/skills/release/SKILL.md`. Its step 5, "Check for performance
regressions (non-patch releases only)" (lines 111 to 148), captures a baseline by running the
benchmark suite in a detached worktree of the last tag and then runs the current tree with
`--baseline` and `--fail-if-slower 10`; the Important Notes bullet at line 206 repeats that the
gate is skipped for patches. The 0.9.0.1 commit `04f2c6b build(deps): support effectful 2.7`
says "Built and tested against effectful 2.7.1.0 / effectful-core 2.7.1.2 ... no source changes
were needed" and, being a patch, ran no benchmark.

The benchmark suite is documented in `shibuya-core-bench/README.md`. Its executable accepts
tasty-bench options: `-l` lists the 57 leaves, `-p '<pattern>'` selects leaves, `--csv <file>`
records a run, `--baseline <file>` compares against one, `--fail-if-slower <pct>` turns a
slowdown into a non-zero exit, and `--stdev <pct>` with `--timeout <secs>` controls precision.
The pattern used for the review's subset was
`'/processing/ || /comparison/ || /noop-handler/ || /concurrency-levels/ || /hot-path/ || /cpu-bound-serial/ || /io-handler/'`.
Building the same tree against two dependency versions side by side works with
`--constraint` and a separate `--builddir`; the review used `dist-eff26` for the 2.6.1 build and
`dist-eff2710` for the 2.7.1.0 build, both of which are gitignored build directories and can be
deleted at any time. All cabal commands in this repository run inside the flake shell
(`nix develop -c cabal ...`).

No ADR exists for this repository; there is no `docs/adr/` directory and Mori lists no ADR
bundle. The two durable decisions here (the exclusion range and the gating rule) are candidates
for a first ADR, to be created at the MasterPlan's completion.


## Plan of Work

### Milestone 1: bounds

Edit the six dependency lines so that each package depends on `effectful-core` with the
exclusion range instead of on `effectful`. Because the imported modules are the same, no
Haskell source changes. Then prove the bound with three dry-run solves and record them. Add a
changelog entry under an `## Unreleased` heading at the top of `shibuya-core/CHANGELOG.md`
(Milestone 4 renames it to `## 0.9.0.3 — <date>` if that remains the next free version). At the end of this
milestone the library, tests, examples, and benchmarks build unchanged, the solver rejects
effectful-core 2.7.1.0, and `cabal check` in `shibuya-core/` still passes.

### Milestone 2: release gate

Rewrite step 5 of `agents/skills/release/SKILL.md` so its heading is "Check for performance
regressions" without the parenthetical, its first paragraph says the gate runs for minor and
major releases and additionally for any release, including a patch, whose diff changes the
admitted versions of a runtime dependency (`effectful-core`, `effectful`, `streamly`,
`streamly-core`, `nqe`, `stm`, any `hs-opentelemetry-*` package), and it gains a second
procedure for the dependency case: build the current tree twice with the old and new versions
pinned into separate build directories, run the subset above on each with `--csv`, then run the
new build with `--baseline` and `--fail-if-slower 10`. Update the Important Notes bullet at
line 206 to match. At the end of this milestone the skill reads consistently and a maintainer
following it for a bound-only patch would run the comparison.

### Milestone 3: evidence

Copy the 2.7.1.0 result from the review's raw log into Surprises & Discoveries beside the
2.6.1-versus-2.7.1 table, or, if the log is gone, reproduce it with the commands below. The
milestone is complete when this plan states, with numbers, how effectful-core 2.7.1.0 compares
with 2.6.1.0 on the same subset, so the exclusion is justified by a measurement on this
framework and not only by the upstream changelog.

### Milestone 4: coordinated core and metrics release

Run the repository release skill after the first three milestones are complete. Recheck live
Hackage versions and upstream tags, choose the next free patch (provisionally 0.9.0.3), rename
the unreleased changelog sections, bump both package versions and the metrics core bound, and
apply the skill's full build, test, benchmark, package, publication, and GitHub-release gates.
This bound-changing patch must run the benchmark procedure introduced by Milestone 2.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

### Milestone 1 steps

In `shibuya-core/shibuya-core.cabal` replace line 75 with

```text
    effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8),
```

and line 140 `effectful,` with `effectful-core,`. In `shibuya-example/shibuya-example.cabal`
replace lines 34 and 65, and in `shibuya-core-bench/shibuya-core-bench.cabal` lines 53, 87,
and 125, with the same `effectful-core` line. Then:

```bash
nix develop -c cabal build --dry-run all --constraint='effectful-core==2.6.1.0'
nix develop -c cabal build --dry-run all --constraint='effectful-core==2.7.1.2'
nix develop -c cabal build --dry-run all --constraint='effectful-core==2.7.1.0'
```

Expected: the first two end with a plan (lines beginning `In order, the following would be
built`) and exit 0; the third exits non-zero with output containing

```text
rejecting: effectful-core-2.7.1.0 (constraint from user target requires ==2.7.1.0)
```

or an equivalent line naming `shibuya-core` as the package whose bound conflicts. Then a real
build and the suite:

```bash
nix develop -c cabal build all
nix develop -c cabal test shibuya-core
(cd shibuya-core && nix develop -c cabal check)
```

Expected: no new warnings, all tests pass, and `cabal check` reports no errors (it may repeat
its existing informational notes). Add to `shibuya-core/CHANGELOG.md` above the 0.9.0.1 section:

```markdown
## Unreleased

### Other Changes

- Depend on `effectful-core` directly, with the range
  `(>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)`, instead of on `effectful`. Every module this
  package imports lives in `effectful-core`; the umbrella `effectful` package was a pass-through.
  The range excludes `effectful-core` 2.7.0.0 through 2.7.1.0, whose changelog records a
  per-operation overhead regression for dynamically dispatched effects (fixed upstream in
  2.7.1.1). shibuya-core's own effects are static and unaffected, but every adapter's queue
  effect is dynamic, and this bound keeps a consumer's solver off those releases. A
  same-tree benchmark of effectful 2.6.1 against 2.7.1 (docs/plans/34) shows 2.7.1 at parity
  on the serial paths and roughly twice as fast on the `Async` hot path.
```

Run `nix fmt`, then commit with a message such as `build(deps): exclude the regressed
effectful-core 2.7.0.0 to 2.7.1.0 releases` and the trailers
`MasterPlan: docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md`
and `ExecPlan: docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`.

### Milestone 2 steps

Edit `agents/skills/release/SKILL.md`. Replace the step 5 heading and opening paragraph with:

```markdown
### 5. Check for performance regressions

Run this step for `minor` and `major` releases, and for **any** release — including a
`patch` — whose diff changes the admitted versions of a runtime dependency: `effectful-core`,
`effectful`, `streamly`, `streamly-core`, `nqe`, `stm`, or any `hs-opentelemetry-*` package.
Skip it only for a `patch` release that touches none of those bounds. The gate guards the
~4x-vs-streamly overhead and per-message allocation budget that EP-30/EP-31 established; a
dependency swap can move both without any shibuya source change (EP-34 measured effectful
2.6.1 against 2.7.1 and found a 2x difference on the `Async` hot path).
```

Keep the existing worktree procedure for source changes, and add after it:

````markdown
For a dependency-bound change, a worktree of the last tag would resolve the same old
dependency as the current tree does before the bound moved, so compare the two dependency
versions on the current tree instead:

   ```bash
   nix develop -c cabal build --builddir=dist-dep-old --constraint='<pkg>==<old>' shibuya-core-bench:bench:shibuya-core-bench
   nix develop -c cabal build --constraint='<pkg>==<new>' shibuya-core-bench:bench:shibuya-core-bench
   OLD=$(find dist-dep-old/build -type f -name shibuya-core-bench -perm -u+x | head -1)
   NEW=$(find dist-newstyle/build -type f -name shibuya-core-bench -perm -u+x | head -1)
   PAT='/processing/ || /comparison/ || /noop-handler/ || /concurrency-levels/ || /hot-path/ || /cpu-bound-serial/ || /io-handler/'
   $OLD -p "$PAT" --stdev 5 --timeout 120 --csv /tmp/shibuya-dep-old.csv
   $NEW -p "$PAT" --stdev 5 --timeout 120 --baseline /tmp/shibuya-dep-old.csv --fail-if-slower 10
   ```

   Interpret the result exactly as in step 3 above, and delete `dist-dep-old` afterwards.
````

Change the Important Notes bullet at line 206 to: "Never skip the benchmark regression check
(step 5) for `minor` and `major` releases, or for any release that changes a runtime
dependency bound. If a genuine regression is found, stop and get the user's decision before
releasing." Commit with the two trailers.

### Milestone 3 steps

The review's raw logs were written under the session scratchpad
`/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-shibuya-project-shibuya/cc9d0abd-94ae-478a-a314-f126b6e2e971/scratchpad/`
as `bench.log` (2.6.1 baseline then 2.7.1 comparison), `bench-hotpath-rerun.log`, and
`bench-2710.log` with CSVs `bench-eff26.csv`, `bench-eff27.csv`, and `bench-eff2710.csv`. If
they still exist, copy the 2.7.1.0 verdict lines into Surprises & Discoveries. If they are gone,
reproduce with the Milestone 2 commands using `<pkg>=effectful-core`, `<old>=2.6.1.0`, and
`<new>=2.7.1.0` (pin `effectful==2.7.1.0` as well for the new build), and record the output.
Expected shape, from the review: `same as baseline` on the serial leaves, since nothing in
shibuya-core is dynamically dispatched.

### Milestone 4 steps

Invoke `agents/skills/release/SKILL.md` for a patch release. Present the concrete version and
changelog diff for confirmation before the release commit. Include both core suites and the
dependency-bound benchmark comparison, publish core before metrics, and record the resulting
tag and Hackage URLs in Outcomes & Retrospective. Every release commit carries this plan's
`ExecPlan:`, the parent `MasterPlan:`, and the active `Intention:` trailer.


## Validation and Acceptance

Milestone 1 is accepted when the three dry-run solves behave as described, `cabal build all`
and both suites selected by `cabal test shibuya-core` pass, and `cabal check` passes. Milestone 2 is accepted when
`agents/skills/release/SKILL.md` contains the new step 5 text and the updated note, and reading
it end to end gives one consistent rule. Milestone 3 is accepted when this plan's Surprises &
Discoveries holds the 2.7.1.0 numbers with the command that produced them.
Milestone 4 is accepted when both packages are published at the reviewed patch version, their
Hackage pages and the matching upstream tag exist, and the GitHub release links both packages.


## Idempotence and Recovery

All edits are text under version control. The dry-run solves change nothing. The extra build
directories (`dist-eff26`, `dist-eff2710`, `dist-dep-old`) are disposable and gitignored;
delete them with `rm -rf` when done. If a benchmark run is disturbed by other load, re-run it;
tasty-bench's `--stdev 5` will take longer but converge.


## Interfaces and Dependencies

No Haskell interface changes. The dependency lines that must hold at the end of Milestone 1:

```text
shibuya-core        library:    effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
shibuya-core        test-suite: effectful-core
shibuya-example     both exes:  effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
shibuya-core-bench  all three:  effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
```

The adapters copy the same expression in
`docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md` and
`docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md`;
if this range changes, change it there in the same commit.


## Revision Notes

2026-09-20 UTC: Split release ownership after plan 33 selected the PVP patch 0.9.0.2 for its
urgent runtime fix. This plan now owns the following bound-changing core/metrics patch,
provisionally 0.9.0.3, and applies its new benchmark gate to that release.
