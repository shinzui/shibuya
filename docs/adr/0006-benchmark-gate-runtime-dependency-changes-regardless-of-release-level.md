# Benchmark-gate runtime dependency changes regardless of release level

Status: Accepted

Date: 2026-09-22

## Context

The release skill used to run its benchmark regression gate only for minor and major releases.
Core 0.9.0.1 moved the admitted `effectful` family from 2.6 to 2.7 but went out as a patch,
because a bound change with no source change is a patch under the PVP. As a result, the first
dependency-family swap on the hot path shipped without being measured.

A later measurement showed that a dependency swap alone can move the hot path a lot. With no
Shibuya source change, the `Async` hot-path leaf ran about twice as fast on effectful 2.7.1 as
on 2.6.1. A swap in the other direction would have been just as invisible.

The skill's baseline procedure also measured nothing in this case. A worktree of the last tag
resolves the same dependency versions as the current tree unless a bound has changed, so
comparing against it cannot isolate the effect of a new dependency version.

## Decision

The benchmark gate is triggered by what the release changes, not only by its PVP level.
Minor and major releases always run it. A release at any level, including a patch, also runs
it when its diff changes the admitted versions of a runtime dependency: `effectful-core`,
`effectful`, `streamly`, `streamly-core`, `nqe`, `stm`, or any `hs-opentelemetry-*` package.

For a dependency change, compare the two dependency versions on the same source tree. Build
the benchmark twice, pinning the old and new versions with `--constraint` into separate
`--builddir`s. Then run the new build against the old build's CSV with `--fail-if-slower`.
Treat an allocation increase as a regression even when time stays within noise.

The gate adds to the release skill's existing test gates, including the process-isolated
garbage-collection suites from
[ADR 0001](0001-remove-obsolete-linked-actors-and-test-gc-liveness.md); it does not replace them.

## Consequences

- A bound-only patch now costs a benchmark run. That is the price of catching a hot-path
  change that no source diff would show.
- The list of runtime dependencies lives in step 5 of the release skill. Adding a hot-path
  dependency means adding it to that list.
- A genuine regression stops the release until the release owner decides.
- The first release to carry this rule, 0.10.0.0, went through a certified candidate under
  [ADR 0002](0002-require-candidate-bound-machine-checkable-release-evidence.md). Its paired
  performance matrix was measured over the frozen solver plan that included the new bound.
  Releases made outside such a candidate still run the one-tree comparison above.

## Evidence

The rule, the one-tree procedure, and the effectful 2.6.1, 2.7.1.0, and 2.7.1.2 measurements
are in
[`docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`](../plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md).
The skill change is commit `a1bf986`, in `agents/skills/release/SKILL.md` step 5 and its
Important notes.
