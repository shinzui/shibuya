---
id: 30
slug: investigate-and-reduce-the-async-ahead-concurrency-allocation-regression
title: "Investigate and reduce the Async/Ahead concurrency allocation regression"
kind: exec-plan
created_at: 2026-07-04T20:59:55Z
---

# Investigate and reduce the Async/Ahead concurrency allocation regression

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a follow-up to EP-29
(`docs/plans/29-fix-nested-atomically-race-in-concurrent-ingester-processor-path.md`), whose
Surprise **S6** first recorded this regression, and it sits under the master plan
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`
(the "performance" remediation strand). All measurements below were taken on the `master`
branch at commit `3344171` (the EP-29 benchmark fix), on an Apple Silicon macOS machine
(aarch64-osx) with GHC 9.12.4 and cabal 3.16.


## Purpose / Big Picture

Shibuya processes a queue by running a user *handler* on each message. Under the `Ahead n` and
`Async n` *concurrency modes*, up to `n` handlers may run at once; the processor loop dispatches
messages to a bounded pool of streamly worker threads. In the 0.7.0.0→0.8.0.0 line, EP-26 M3
made the configured concurrency a **hard streamly thread bound** by adding `StreamP.maxThreads n`
to the dispatch. That was a deliberate *correctness* change — without it, `Async 5` could run
**more than 5** handlers concurrently, silently violating a limit users rely on (database pool
size, rate limits, downstream connection caps).

That correctness fix came with a **deterministic allocation regression** on the concurrent
paths, never measured against 0.7.1.0 at the time. EP-29's M5 re-benchmark quantified it (see
Surprises S1 / the EP-29 S6 note): the `concurrency-levels` `async`/`ahead` benchmarks allocate
**+40%–89%** more than 0.7.1.0, while every non-concurrent path is flat.

This plan does **not** touch the concurrency guarantee. Its purpose is narrow: determine whether
that extra allocation is **inherent** to bounding worker threads, or a **fixable inefficiency**
(e.g. a `maxBuffer`/`maxThreads` interaction, or a streamly config knob), and:

- If a safe, allocation-reducing change exists that **keeps** the hard `n`-thread bound and all
  existing semantics (ordering for `Ahead`, exactly-once finalization, halt, backpressure), apply
  it and prove the reduction against the 0.7.1.0 baseline.
- Otherwise, **accept** the cost and document, in code and here, that it is the price of the
  concurrency guarantee — so it is a recorded decision, not an untracked regression.

Observable outcome: after this plan, `docs/plans/30-…md` contains a measured before/after
allocation table and a decision; and either the dispatch in
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` allocates measurably less on the
`concurrency-levels` benchmarks with the concurrency guarantee intact (all tests still green), or
a code comment at the dispatch site records why the current allocation is necessary.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (from EP-29 M5): quantified the regression vs `v0.7.1.0` — see Surprises S1. (2026-07-04)
- [ ] M1: Characterize the regression — is the extra allocation **fixed per run** or **per
      message / per worker**? Does it scale with `n`? Attribute it to `maxThreads n`
      specifically by toggling it in a scratch build.
- [ ] M2: Try allocation-reducing variants that keep the hard `n`-thread bound (see Plan of
      Work) and measure each against the `v0.7.1.0` baseline (Allocated column) and against
      pre-change `master`.
- [ ] M3: Decide — apply the best safe win, or accept + document. Record in Decision Log.
- [ ] M4: If a code change is made: run the full test suite, the `prod-stress` guard
      (`shibuya-core-bench:exe:prod-stress`), and re-benchmark to confirm the reduction and no
      new regression / no semantic change. If accepting: add a comment at the dispatch site.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

### S1 — The regression, quantified vs `v0.7.1.0` (from EP-29 M5, 2026-07-04)

Allocation (the deterministic signal; timing was "same as baseline" everywhere) for
`concurrency-modes.concurrency-levels.*`, `v0.7.1.0` → `master` (`3344171`):

```text
async-100msgs-1ms:  1.38MB → 2.61MB  (+88.8%)
                    2.13MB → 3.09MB  (+44.9%)
                    1.23MB → 1.72MB  (+40.0%)
                    1.47MB → 1.47MB  ( +0.3%)
ahead-100msgs-1ms:  2.12MB → 2.49MB  (+17.5%)
                    (other ahead levels within ±1%)
```

(The four `async` rows are the `async-2/5/10/20` leaves; CSV row order does not map 1:1 to the
labels — M1 must re-run with labels attached.) Non-concurrent paths — streamly baselines,
`adapter-creation`, `processing`, `handler-overhead`, `cpu-bound-serial` — are flat (±1%).
Timing did **not** regress (async modes were slightly faster, 0.78–0.95×).

### S2 — The introducing change (EP-26 M3): `maxThreads n` added to the dispatch

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, in `processUntilDrained`, the
non-partitioned `Ahead`/`Async` branches (at `3344171`, ~lines 521–526):

```haskell
(_, Ahead n) ->
  Stream.fold Fold.drain $
    StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer n . StreamP.ordered True) processAction inboxStream
(_, Async n) ->
  Stream.fold Fold.drain $
    StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer n) processAction inboxStream
```

Per EP-26, 0.7.1.0 used `StreamP.maxBuffer n` alone. `maxBuffer n` bounds buffered *outputs*, not
the number of in-flight worker threads, so it does **not** cap concurrent handler executions;
`maxThreads n` does. Reverting `maxThreads n` would reclaim the allocation but reintroduce the
concurrency-bound violation EP-26 fixed — so it is out of scope (Decision Log).


## Decision Log

Record every decision made while working on the plan.

- Decision: Do **not** revert `StreamP.maxThreads n`. Rationale: it is the mechanism that makes
  `Async n`/`Ahead n` a hard "at most `n` concurrent handlers" guarantee; users depend on that
  bound for resource safety (pools, rate limits). Reverting to reclaim allocation would
  reintroduce a correctness bug. This plan only looks for reductions that keep the bound.
  Date: 2026-07-04.

- Decision: Judge regressions on the deterministic **Allocated** column (compared vs the
  `v0.7.1.0` baseline built in a detached worktree), not wall-clock time. Rationale: established
  in EP-29 — small-batch timing swings (±10–20%) are measurement noise; allocation is
  reproducible. Date: 2026-07-04.

- Decision: Treat this as a self-contained follow-up rather than reopening EP-29. Rationale: the
  crash fix (EP-29) is shipped and orthogonal; conflating a performance investigation with it
  would muddy both. Date: 2026-07-04.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything relevant lives in `shibuya-core` and `shibuya-core-bench`. Read these before editing:

- `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` — `processUntilDrained` holds the
  dispatch. The `maxConc` binding maps `Serial→1`, `Ahead n→n`, `Async n→n`. The four relevant
  branches: `(_, Serial)` (streamly serial `Stream.mapM`), `(PartitionedInOrder, Ahead/Async n)`
  (the `runKeyedScheduler` path — **do not** change here unless M2 says so), and the
  non-partitioned `(_, Ahead n)` / `(_, Async n)` branches carrying `StreamP.maxThreads n`. The
  per-message work is `processAction = runInIO . processOne …` (metrics + tracing + handler +
  finalize); its cost is identical across modes and is **not** the regression.
- `shibuya-core-bench/bench/Bench/Concurrency.hs` — the benchmark. `runWithConcurrency`:
  `Serial` uses `runWithMetrics`; `Ahead`/`Async` use `runSupervised master 100 … Unordered`.
  The regressed leaves are under `concurrency-modes.concurrency-levels`:
  - `ahead-100msgs-1ms` → `ahead-2/5/10/20` (100 msgs, `ioBoundHandler 1000` = 1ms `threadDelay`)
  - `async-100msgs-1ms` → `async-2/5/10/20` (same, `Async`)
  The `io-bound` group (`ioBoundBenchmarks`) is separate and its leaves **time out** under
  `--stdev`-driven runs; exclude them with `-p '!/io-bound/'` (they are not the regression).
- `shibuya-core-bench/bench/Test/ProdStress.hs` (exe `prod-stress`, added in EP-29) — a
  production-shape stress of `runSupervised` across Serial/Ahead/Async that fails if a nested
  `atomically` ever occurs. Re-run it after any dispatch change as a correctness guard.
- streamly config combinators live in `Streamly.Data.Stream.Prelude` (imported as `StreamP`):
  `parMapM`, `maxThreads`, `maxBuffer`, `ordered`, `eager`, `rate`/`avgRate`, `interleaved`.
  Consult the streamly source on disk (via `mori`; do **not** read `/nix/store`) for exact
  semantics before using any of them.

Terms, in plain language:

- **`maxThreads n`**: cap streamly's concurrent worker threads at `n` — the hard concurrency
  bound. **`maxBuffer n`**: cap the number of buffered/outstanding results at `n`; does not by
  itself bound in-flight worker count. **`ordered True`** (Ahead only): emit results in input
  order. **`eager`**: start producing/consuming eagerly rather than lazily. **`Allocated`**: bytes
  allocated during the measured action, reported by tasty-bench via `GHC.Stats` (deterministic).
- **partitioned path**: for `PartitionedInOrder` ordering, dispatch goes through
  `runKeyedScheduler`, not `parMapM`. The regression benchmarks use `Unordered`, so they hit the
  `parMapM` branches; keep the two paths' behavior aligned if you touch one.


## Plan of Work

Four milestones. M1 characterizes the regression; M2 tries reductions; M3 decides; M4 validates.
No milestone may loosen the `n`-thread concurrency bound or change observable semantics
(ordering for `Ahead`, exactly-once finalization, halt, backpressure).

### Milestone M1 — Characterize and attribute the regression

Scope: turn S1's raw numbers into a labelled, understood shape. Re-run the two regressed groups
with labels attached and confirm the per-leaf deltas. Determine whether the extra allocation is
**fixed per run**, **per message**, or **per worker/`n`** — e.g. by also running a variant with a
larger message count (change `100` to `1000` locally) and seeing whether the absolute delta
scales with messages or with `n`. Attribute it to `maxThreads n` specifically: in a scratch edit,
temporarily drop `maxThreads n` (keeping `maxBuffer n`) and confirm the allocation returns toward
the 0.7.1.0 level (this is a measurement only — it is **not** the fix, since it breaks the bound).

At the end of M1 we can state, with numbers, "the regression is `+X` bytes per {run|message|
worker}, and it is caused by `maxThreads n`." Record in Surprises.

Acceptance: a labelled before/after table and an attribution statement in this plan.

### Milestone M2 — Try allocation-reducing variants that keep the bound

Scope: measure candidates, each of which must preserve the hard `n`-thread cap. Candidates to
consider (choose/extend based on M1 and streamly's source):

- **`maxBuffer` tuning**: try `maxBuffer (n)` vs the current pairing, and a larger buffer (e.g.
  `maxBuffer (2*n)`), to see whether the allocation is buffer-churn rather than thread-bounding.
- **`eager`**: `StreamP.eager True` alongside `maxThreads n . maxBuffer n` — a different
  scheduling discipline that may allocate less for IO-bound work.
- **Rate/scheduling knobs** only if they do not change the thread cap.
- **Avoid double config**: check whether `maxThreads n . maxBuffer n` is doing redundant work vs
  a single combinator that expresses the same bound.

For each candidate: edit the `(_, Ahead n)` / `(_, Async n)` branches, rebuild, and run the
`concurrency-levels` benchmarks against the `v0.7.1.0` baseline (Concrete Steps). Keep a table of
Allocated deltas per candidate. Discard any candidate that changes ordering/finalization/halt
behavior or loosens the bound (verify via the test suite and `prod-stress`).

Acceptance: a per-candidate allocation table; at least one candidate identified as "keeps bound,
reduces allocation" — or a documented finding that none do.

### Milestone M3 — Decide

Scope: from M2, either (a) select the best safe reduction, or (b) conclude the cost is inherent.
Record the decision and rationale in the Decision Log. If (b), the deliverable is a short comment
at the dispatch site in `Supervised.hs` explaining that `maxThreads n` is required for the
concurrency bound and that its allocation cost was measured and accepted (cite this plan).

### Milestone M4 — Validate

Scope: if a code change was made in M3(a): run `cabal test shibuya-core-test` (all green,
semantics unchanged), run `prod-stress` (no nested `atomically`, correct counts), and re-run the
full benchmark suite vs `v0.7.1.0` to confirm the allocation reduction on the `concurrency-levels`
leaves and **no** new regression elsewhere. If M3(b): confirm the comment is in place and the
suite is unchanged.

Acceptance: tests green; `prod-stress` clean; benchmark table showing the intended allocation
change (down for a fix, or unchanged-and-documented for acceptance).


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` unless stated otherwise.

### Build the `v0.7.1.0` allocation baseline (once)

```bash
git worktree add --detach /tmp/wt-0710 v0.7.1.0
( cd /tmp/wt-0710 && cabal build --enable-benchmarks shibuya-core-bench )
OLD=$(find /tmp/wt-0710/dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
"$OLD" --csv /tmp/old.csv --stdev 20 --timeout 45 -p '!/io-bound/' +RTS -N
# ... remove when done:
git worktree remove --force /tmp/wt-0710
```

### Measure a candidate (repeat per M2 variant)

```bash
cabal build --enable-benchmarks shibuya-core-bench
NEW=$(find dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
# focus on the regressed groups; compare against the baseline:
"$NEW" --baseline /tmp/old.csv --stdev 20 --timeout 45 -p '/concurrency-levels/' +RTS -N
# and capture a CSV to diff allocation precisely:
"$NEW" --csv /tmp/new.csv --stdev 20 --timeout 45 -p '!/io-bound/' +RTS -N
```

Diff the deterministic Allocated column (v0.7.1.0 → candidate) with a short script over
`/tmp/old.csv` and `/tmp/new.csv` (column header `Allocated`); the EP-29 M5 session used a small
Python `csv` reader to print `old`, `new`, and `delta%` per leaf — reuse that shape and expect the
`concurrency-levels.async/ahead` rows to move while all other rows stay flat.

### Correctness guards after any dispatch edit

```bash
cabal test shibuya-core-test
PS=$(find dist-newstyle -type f -path '*x/prod-stress*' -name prod-stress)
"$PS" 60 8 2000 +RTS -N -T -A32m   # expect: nested-atomically crashes (any thread)=0
```

Expected `prod-stress` tail:

```text
DONE. total processed=960000   nested-atomically crashes (any thread)=0
no nested atomically in production path across this run
```


## Validation and Acceptance

The change is validated by measured allocation and preserved behavior, not compilation:

1. **Regression characterized (M1):** this plan states the per-leaf allocation delta with labels
   and whether it scales per-run / per-message / per-`n`, and attributes it to `maxThreads n`.
2. **Reduction or acceptance (M3):** either a candidate shows a real Allocated drop on
   `concurrency-levels.async/ahead` vs `v0.7.1.0` **with the `n`-thread bound intact**, or the
   Decision Log records acceptance with a code comment at the dispatch site.
3. **Semantics preserved:** `cabal test shibuya-core-test` is fully green (ordering, exact
   `processed`/`failed` counts, halt behavior, batch conservation unchanged), and `prod-stress`
   reports zero nested `atomically` with correct totals.
4. **No collateral regression:** the full benchmark suite vs `v0.7.1.0` shows the intended change
   on the concurrency leaves and flat Allocated elsewhere (streamly baselines, processing,
   handler-overhead, cpu-bound-serial).


## Idempotence and Recovery

All steps are safe to repeat. Benchmark/scratch builds go to `dist-newstyle` and do not alter
source unless you edit it; any experimental dispatch edit must be reverted before the final state
unless it is the accepted fix. Recover a clean tree for the source under investigation with:

```bash
git checkout -- shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs
git status --porcelain   # expect empty (aside from intended, committed changes)
```

The `git worktree` baseline is disposable: `git worktree remove --force /tmp/wt-0710`. Benchmark
timing is noisy — always compare the **Allocated** column, and run on a quiescent machine; a
single run's timing is not evidence.

Every commit for this plan must carry the trailer:

```text
ExecPlan: docs/plans/30-investigate-and-reduce-the-async-ahead-concurrency-allocation-regression.md
```


## Interfaces and Dependencies

- `Streamly.Data.Stream.Prelude` (as `StreamP`): `parMapM`, `maxThreads`, `maxBuffer`, `ordered`,
  and candidate knobs `eager`, `rate`/`avgRate`. The dispatch must keep a hard `n`-thread bound
  (`maxThreads n` or an equivalent that provably caps in-flight workers at `n`).
- `Streamly.Data.Stream` (as `Stream`) / `Streamly.Data.Fold` (as `Fold`): `fold`, `drain`,
  `mapM` — the serial path and the fold driver; unchanged by this plan.
- `shibuya-core-bench` benchmark (`Bench.Concurrency`) and the `prod-stress` executable — the
  measurement and correctness harnesses.

At the end of this plan, the public signatures of `runSupervised`, `runWithMetrics`,
`runIngesterAndProcessor`, `processUntilDrained`, and `inboxToStream` are **unchanged**; any fix
is internal to the streamly config passed to `parMapM`. If a signature must change, record it here
and in the Decision Log with rationale.
