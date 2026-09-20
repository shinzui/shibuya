# EP-39 metrics lifecycle evidence

This directory retains the focused Milestone 2 performance measurements. Functional
negative controls and the full passing commands are recorded in
`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`.

## Identity

- Baseline source: `682003e7e20bcbf49a5a6e1295fc9efdc6677395`
- Accepted candidate source: `82a8e90f02b5c52a291a4655ee34c604d8fdb2e9`
- Compiler: GHC 9.12.4, optimization profile `-O1` library / `-O2` benchmark
- Solver plan SHA-256: `c099947407a29e3f2c2d6508067369c53593d6ac5e3a6584cda33d168324b53b`
- Machine: `MacBookPro18,2`, Darwin 25.6.0 arm64, 10 logical CPUs
- RTS: `-N1`, benchmark arena `-A32m`

## Commands

The baseline was built in a detached worktree at the baseline SHA:

```bash
cabal bench shibuya-core-bench --benchmark-options='-p hot-path --stdev 3 --timeout 120 --csv /tmp/ep39-hotpath-baseline.csv +RTS -N1 -RTS'
```

The rejected direct-clock candidate and accepted sampler candidate used:

```bash
cabal bench shibuya-core-bench --benchmark-options='-p hot-path --stdev 3 --timeout 120 --baseline /tmp/ep39-hotpath-baseline.csv --fail-if-slower 5 --csv <candidate.csv> +RTS -N1 -RTS'
```

`direct-clock-candidate.csv` failed both cells: serial was reported 28% slower and
async8 12% slower. `sampler-candidate.csv` passed both 5% comparisons and retained
the baseline allocation class. CSV means and two-standard-deviation estimates are
the raw tasty-bench outputs, not a substitute for EP-45's final paired candidate
matrix.

## Correctness

An isolated worktree at the baseline SHA ran five added health regressions. All
five failed: separated bursts and sustained progress were falsely stuck, an
unregistered configured failure became ready, a stopped master remained live,
and a hung dependency outlived the outer test bound. The accepted candidate ran
36 metrics examples, 236 ordinary core examples, and both isolated core GC suites
with zero failures.
