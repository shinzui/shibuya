---
id: 31
slug: investigate-and-reduce-the-shared-per-message-metrics-tracing-finalize-allocation-regression
title: "Investigate and reduce the shared per-message metrics/tracing/finalize allocation regression"
kind: exec-plan
created_at: 2026-07-04T22:09:49Z
---

# Investigate and reduce the shared per-message metrics/tracing/finalize allocation regression

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a follow-up to EP-30
(`docs/plans/30-investigate-and-reduce-the-async-ahead-concurrency-allocation-regression.md`),
whose Surprise **S6** first isolated this regression. EP-30 fixed the Async/Ahead *dispatch*
allocation (via `maxBuffer (2*n)`); this plan targets the **separate, shared per-message**
allocation increase that EP-30's fix does not touch. All measurements were taken on `master` at
commit `0a7d8ff` (the EP-30 fix) vs the `v0.7.1.0` tag, on Apple Silicon macOS (aarch64-osx),
GHC 9.12.4, cabal 3.16.


## Purpose / Big Picture

Shibuya runs a user *handler* on each message. Every message flows through a shared function,
`processOne` (in `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`), which does metrics,
tracing, the handler call, and finalization — the same code for **all** concurrency modes
(Serial, Ahead, Async). Between `0.7.1.0` and `0.8.0.0` this shared path grew ~**4–9%** more
allocation *per message*, on top of adding features (in-flight metrics, bounded finalize retry,
handler-exception isolation). Because it is per-message and shared, it shows up on every path —
including the pure-Serial benchmarks — and it is the ~+20% residual left on the Async
`concurrency-levels` leaves after EP-30's buffer fix.

This plan determines how much of that increase is a **fixable inefficiency** (e.g. two STM
metrics transactions where one would do, or eager tracing-argument allocation that survives even
a no-op tracer) versus the **inherent cost of the new features**, and then either:

- applies safe, semantics-preserving reductions and proves them against the `v0.7.1.0` baseline
  on the deterministic Allocated column, keeping every observable behavior (exact `processed`/
  `failed`/in-flight metrics, ordering, halt, finalization exactly-once, tracing output when a
  real tracer is installed), **or**
- accepts and documents, in code and here, that the remaining cost is the price of the metrics/
  introspection and finalization-retry features — a recorded decision, not an untracked
  regression.

Observable outcome: after this plan, this file contains a measured before/after allocation table
attributing the shared regression to specific per-message work, and either `processOne` (and the
metrics/finalize helpers it calls) allocate measurably less on the `handler-overhead` /
`processing` / `comparison` benchmarks with all tests green, or a code comment records why the
current allocation is necessary.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (from EP-30 S6): quantified the shared regression vs `v0.7.1.0` and established it is not
      streamly and not the dispatch config — see Surprises S1. (2026-07-04)
- [x] M1: diffed `processOne` `v0.7.1.0` → `master` (S2) and attributed the delta by subtractive
      bisection (S3). Result: the regression is ~126 B/msg, caused by the **second per-message
      `catchAny`** master added (handler catch + `finalizeWithRetry`'s catch, vs `0.7.1.0`'s single
      combined catch). Metrics were a red herring (now cheaper via atomic counters); tracing args
      are cheap under the no-op tracer. (2026-07-04)
- [x] M2/M3: decided to **accept + document** rather than reduce. The regression is the price of a
      correctness improvement (always-finalize), not waste; reducing it means swapping
      exception primitives (async-exception-sensitive) for a ~5% gain. Added explanatory comments
      at both catch sites citing this plan. (2026-07-04)
- [x] M4: comments in place at both catch sites; `shibuya-core` builds clean and
      `cabal test shibuya-core-test` passes 201/201 (comment-only change, no functional diff).
      (2026-07-04)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

### S1 — The shared regression, quantified vs `v0.7.1.0` (from EP-30 S6, 2026-07-04)

Allocation (deterministic; timing flat) for the shared/serial paths, `v0.7.1.0` → `master`
(`0a7d8ff`). These paths do **not** use `maxThreads`/the concurrent dispatch, so EP-30's buffer
fix leaves them unchanged:

```text
framework-overhead.processing.runWithMetrics-100     222.42KB → 241.97KB  (+8.8%)
framework-overhead.processing.runWithMetrics-1000      2.18MB →   2.32MB  (+6.2%)
framework-overhead.processing.runWithMetrics-10000    22.16MB →  23.39MB  (+5.5%)
handler-overhead.noop-handler.100-msgs               291.62KB → 311.69KB  (+6.9%)
handler-overhead.noop-handler.1000-msgs                2.89MB →   3.03MB  (+4.6%)
handler-overhead.noop-handler.10000-msgs              29.67MB →  30.90MB  (+4.2%)
framework-overhead.comparison.100-msgs.shibuya        309.61KB → 330.86KB  (+6.9%)
```

The percentage is larger at small batch (100) and shrinks toward ~+4% at 10k, indicating a mostly
per-message component plus a small fixed per-run component. Streamly baselines,
`adapter-creation`, and `cpu-bound-serial` are flat (±1%). The same shared cost is the ~+20%
residual on the Async `concurrency-levels` leaves that EP-30's `maxBuffer (2*n)` could not remove
(EP-30 S4/S5: it is present even with an unbounded output buffer).

### S2 — What changed in `processOne`, `v0.7.1.0` → `master` (M1 read-only, 2026-07-04)

Diffing `git show v0.7.1.0:shibuya-core/src/Shibuya/Runner/Supervised.hs` against
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`. Note master actually *improved* the
attribute map (builds `constantFrameworkAttrs` once per processor and does 1–2 `HashMap.insert`
per message, vs `0.7.1.0`'s per-message `HashMap.fromList` of 4–5 entries), so the regression is
**not** attribute construction. The per-message *additions* in master are:

1. **~~An extra STM metrics transaction per message.~~ WRONG — corrected in S3.** Master's
   `beginProcessing`/`finishProcessing` use `Data.Atomics.Counter` (`incrCounter`, atomic word,
   ~zero allocation) and only touch STM (`atomically $ modifyTVar' handle.cold`) on burst-start or
   failure — **not** per message. `0.7.1.0` did a per-message `getCurrentTime` (allocates a
   `UTCTime`) **plus** a per-message `atomically $ modifyTVar'`. So the metrics path is actually
   *cheaper* per message in master. This hypothesis was disproved by reading `Metrics.hs`; it is
   **not** the regression.
2. **`finalizeWithRetry traceSpan ingested decision`** (in
   `shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs`) — a separate bounded-retry finalizer
   whose happy path is `catchAny (Right <$> ingested.ack.finalize decision) …`, vs `0.7.1.0`'s
   inline `ingested.ack.finalize decision` inside the *handler's* catch. This is a **second
   per-message `catchAny`**. **Confirmed the dominant cost in S3.**
3. **Handler-exception isolation restructured.** Master wraps only the handler in `catchAny`
   (`Right <$> handler …`), then finalizes separately. `0.7.1.0` wrapped handler+finalize in
   **one** `catchAny`. So master installs **two** per-message exception frames where `0.7.1.0`
   installed one. **This split is the regression (S3).** It is a deliberate behavior change: master
   finalizes even when the handler throws (the adapter always sees a decision); `0.7.1.0` skipped
   finalization on a handler exception.
4. **Eager tracing-argument construction — small under the no-op tracer.** Under `runTracingNoop`,
   `tracingEnabled = False`, so `withSpan'` runs `f dummySpan` and each `addAttribute`/`addEvent`/
   `setStatus` is `pure ()` **without forcing its argument** (`Shibuya/Telemetry/Effect.hs`). The
   attribute/event thunks are therefore built but mostly not evaluated. Not the main cost.

### S3 — Attribution: the two per-message `catchAny` sites dominate (M1, 2026-07-04)

Subtractive bisection via a scratch `SHIBUYA_EP31` flag in `processOne` (two toggles: skip the
handler `catchAny`; replace `finalizeWithRetry` with a direct `ingested.ack.finalize`). Allocated,
10000-msg leaves (per-message = Δ / 10000; the scratch flag's own per-message cost is constant
across all rows so the deltas are clean):

```text
                              runWithMetrics-10k   Δ B/msg      noop-handler-10k   Δ B/msg
default (both catches)              24114 KB          —              31793 KB          —
- handler catchAny                  21789 KB        -232             29458 KB        -233
- finalizeWithRetry                 20829 KB        -328             28519 KB        -327
- both                              18489 KB        -562             26191 KB        -560
```

The toggles are additive: ~232 (handler catch) + ~328 (finalize catch, which also carries the
`go delays` closure) ≈ 560 B/msg of reducible per-message exception-handling allocation. The
**regression** vs `v0.7.1.0` is ~**126 B/msg** (`runWithMetrics-10000` 22.16→23.39 MB =
+1.23 MB / 10000). That reconciles: `v0.7.1.0` had **one** `catchAny` per message (handler+finalize
together); master has **two** (handler catch + `finalizeWithRetry`'s catch). The added catch ≈ the
regression, partially offset by the now-cheaper metrics path (item 1). Attribution complete: the
shared regression is the cost of the **second per-message exception frame** introduced by splitting
handler-catch from finalize-catch — a deliberate correctness change (always finalize).


## Decision Log

Record every decision made while working on the plan.

- Decision: Judge on the deterministic **Allocated** column (vs the `v0.7.1.0` baseline built in a
  detached worktree), not wall-clock time. Rationale: established in EP-29/EP-30 — small-batch
  timing is noise; allocation is reproducible (EP-30 confirmed ±1–2% run-to-run even for the
  concurrent leaves). Date: 2026-07-04.

- Decision: Do **not** remove features (in-flight metrics, finalize retry, handler-exception
  isolation) to reclaim allocation. Rationale: they are observable behavior users depend on; this
  plan only looks for reductions that preserve every metric value, count, ordering, halt, and
  finalization guarantee. Date: 2026-07-04.

- Decision: Treat this as a self-contained follow-up to EP-30 rather than reopening it. Rationale:
  EP-30's dispatch fix is shipped and orthogonal; the shared per-message path is a distinct code
  region with a distinct root cause. Date: 2026-07-04.

- Decision (M3): **Accept and document** the ~126 B/message shared regression; do not attempt a
  code reduction. Rationale: M1/S3 proved it is the cost of the *second per-message `catchAny`*
  master added to guarantee always-finalize (the adapter always observes a finalization decision,
  even when the handler throws) plus bounded finalizer retry — a deliberate correctness
  improvement over `0.7.1.0`, not waste. The only reductions available (swap `UnliftIO.catchAny`
  for effectful-native catch; merge the two catches) trade a ~5% per-message allocation gain for
  async-exception-handling risk on the hot path, which is not worth it. Deliverable: explanatory
  comments at both catch sites (`processOne` in `Supervised.hs`, `finalizeWithRetry` in
  `Finalize.hs`) so the cost is a recorded, intentional decision. Date: 2026-07-04.

- Decision (correction): The initial S2 hypothesis that an extra per-message STM *metrics*
  transaction caused the regression was **wrong**. Reading `Metrics.hs` showed
  `beginProcessing`/`finishProcessing` use atomic counters and only hit STM on burst-start/failure;
  the metrics path is *cheaper* per message than `0.7.1.0`'s per-message `getCurrentTime`+STM.
  Recorded so the wrong lead is not re-investigated. Date: 2026-07-04.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-07-04).** The purpose was to determine whether the shared per-message allocation
increase (~+4–9%) is a fixable inefficiency or the inherent cost of new features, and to reduce it
or accept+document. Result: it is the **inherent cost of a correctness feature**. Attribution
(S3) pinned the ~126 B/message regression to the *second per-message `catchAny`* master added by
splitting handler-catch from finalize-catch so that finalization always runs (even on a handler
exception), plus the bounded finalizer retry in `finalizeWithRetry`. `0.7.1.0` used a single
combined catch and skipped finalization when the handler threw. Decision: **accept + document** —
comments now sit at both catch sites (`processOne`, `finalizeWithRetry`) recording the measured
cost and the always-finalize rationale, so the cost is intentional and won't be "optimized" away by
re-merging the catches.

**Lessons / gaps.** Two eyeball hypotheses were wrong and were caught only by reading the code and
measuring: (1) the metrics begin/finish split does **not** cost per-message STM (it uses atomic
counters and is cheaper than `0.7.1.0`'s per-message `getCurrentTime`+STM); (2) tracing-argument
construction is cheap under the no-op tracer (`tracingEnabled = False` short-circuits before forcing
arguments). The reducible cost that *does* exist (~560 B/msg across both catches) is real but was
deliberately not pursued: trading it away means changing exception primitives on the hot path,
which is not worth ~5% here. Not addressed (out of scope): whether effectful-native catch would be
a safe pure win — left as a possible future micro-optimization, not a regression fix.


## Context and Orientation

Everything relevant lives in `shibuya-core` and `shibuya-core-bench`.

- `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` — holds `processOne` (the shared
  per-message function; ~line 549) and the serial driver `Stream.mapM processOne inboxStream`.
  `processOne` runs for every message in every mode, so its per-message allocation is what this
  plan measures. The signature and the set of metric side effects (`beginProcessing`,
  `finishProcessing`, `finishFinalizationFailure`) must not change observably.
- `shibuya-core/src/Shibuya/Core/Metrics.hs` — `beginProcessing`, `finishProcessing`,
  `finishFinalizationFailure`, and the `MetricsHandle` (a hot/cold `TVar` split). The two-STM-
  transactions-per-message pattern lives here; a candidate reduction is to expose a combined
  begin+finish or to move in-flight tracking to a cheaper representation (e.g. an atomic counter)
  without changing the sampled values.
- `shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs` — `finalizeWithRetry`, the bounded-retry
  finalizer. A candidate is to make the no-retry common path (finalizer succeeds first try)
  allocate no more than the old inline `finalize decision`.
- `shibuya-core/src/Shibuya/Telemetry/Effect.hs` — the `Tracing` effect and `runTracingNoop`.
  If `addEvent`/`addAttribute`/`setStatus`/`mkEvent` force their arguments eagerly, a no-op tracer
  still pays for argument construction; a candidate is to make the no-op interpreter (and the call
  sites) avoid building `Text`/attribute lists when no real tracer is present.
- `shibuya-core-bench/bench/Bench/Framework.hs` and `Bench/Handler.hs` — the benchmarks that
  exercise this path: `framework-overhead.processing.runWithMetrics-*`,
  `framework-overhead.comparison.*.shibuya-framework`, and `handler-overhead.*`. They run under
  `runTracingNoop` (no real tracer), so any tracing-argument allocation they show is pure waste
  for the no-tracer case.
- `shibuya-core-bench/bench/Test/ProdStress.hs` (exe `prod-stress`) — correctness guard; re-run
  after any metrics/finalize change to confirm counts and no nested `atomically`.

Terms: **Allocated** = bytes allocated during the measured action (tasty-bench via `GHC.Stats`,
deterministic). **`runTracingNoop`** = a `Tracing` interpreter that discards all spans/events/
attributes; the benchmarks use it, so anything it still allocates is avoidable in the no-tracer
case. **hot/cold TVar split** = `MetricsHandle` keeps frequently-updated counters separate from
rarely-read state to reduce STM contention.


## Plan of Work

Four milestones. M1 attributes the regression to specific per-message work; M2 tries reductions;
M3 decides; M4 validates. No milestone may change an observable metric value, a processed/failed
count, ordering, halt behavior, the exactly-once finalization guarantee, or the tracing output
when a real tracer is installed.

### Milestone M1 — Attribute the shared regression to specific work

Scope: turn S1's "+4–9%" into "+X bytes/message split as …". Build the `v0.7.1.0` baseline and the
current `master` CSVs (Concrete Steps). Then attribute by **subtractive bisection** behind a
scratch env flag in `processOne` (same technique EP-30 used): temporarily no-op one addition at a
time and measure the Allocated drop on `handler-overhead.noop-handler.100-msgs` and
`processing.runWithMetrics-100`:

- (a) collapse `beginProcessing` + `finishProcessing` to a single STM transaction (or skip
  `beginProcessing`) — measures the extra-transaction cost;
- (b) replace `finalizeWithRetry` with a direct `ingested.ack.finalize decision` — measures the
  finalize-wrapper cost;
- (c) stub the per-message `addEvent`/`addAttribute`/`setStatus`/`mkEvent` argument construction —
  measures the eager-tracing-args cost under the no-op tracer.

Optionally corroborate with a `-hT`/`-p` heap or cost-centre profile of `runWithMetrics-10000`.
These are measurements only; the stubs are reverted before M2's real fixes.

Acceptance: a per-cause byte attribution table in Surprises, summing to ~the S1 delta.

### Milestone M2 — Try semantics-preserving reductions

Scope: for each attributed cause, implement a reduction that keeps behavior, and measure it:

- **Metrics**: combine begin/finish into one transaction where possible, or represent in-flight as
  an atomic counter read during sampling — without changing any sampled value. Verify via the
  metrics tests.
- **Finalize**: make the first-try-success path allocate no more than the old inline finalize
  (e.g. avoid building the retry schedule/closures until a retry is actually needed).
- **Tracing**: make `runTracingNoop` (and/or the `Tracing` effect ops) avoid forcing argument
  construction when no real tracer is installed — the biggest likely pure win for the no-tracer
  benchmarks. Confirm a *real* tracer still receives identical events/attributes (a tracing test).

For each candidate: edit, rebuild, run the affected benchmarks vs the `v0.7.1.0` baseline, and keep
a table of Allocated deltas. Discard any candidate that changes an observable value.

Acceptance: a per-candidate table; at least one candidate identified as "keeps behavior, reduces
allocation", or a documented finding that a given cost is inherent.

### Milestone M3 — Decide

Scope: apply the best safe reductions and/or conclude the remainder is the inherent cost of the
metrics/introspection + finalize-retry features. Record in the Decision Log. If accepting, add a
short comment at `processOne`/the relevant helper explaining that the per-message cost was measured
and is the price of the feature (cite this plan).

### Milestone M4 — Validate

Scope: if code changed — `cabal test shibuya-core-test` fully green (metrics values, processed/
failed counts, halt, ordering, finalization all unchanged), `prod-stress` clean (correct totals, 0
nested `atomically`), and the full benchmark suite vs `v0.7.1.0` showing the intended reduction on
`handler-overhead`/`processing`/`comparison` and no new regression elsewhere (including no
regression on the EP-30 concurrency leaves). If accepting: confirm the comment is in place.

Acceptance: tests green; `prod-stress` clean; benchmark table showing the intended change.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` unless stated otherwise. Reuse EP-30's
harness and the `diff_alloc.py` shape (compare the deterministic `Allocated` CSV column).

### Build the `v0.7.1.0` allocation baseline (once)

```bash
git worktree add --detach /tmp/wt-0710 v0.7.1.0
( cd /tmp/wt-0710 && cabal build --enable-benchmarks shibuya-core-bench )
OLD=$(find /tmp/wt-0710/dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
"$OLD" --csv /tmp/old.csv --stdev 20 --timeout 45 -p '!/io-bound/' +RTS -N
# remove when done:  git worktree remove --force /tmp/wt-0710
```

### Measure the shared-path leaves (repeat per M1 stub / M2 candidate)

```bash
cabal build --enable-benchmarks shibuya-core-bench
NEW=$(find dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
# focus on the shared paths; compare deterministic Allocated vs baseline:
"$NEW" --csv /tmp/new.csv --stdev 20 --timeout 45 \
  -p '/handler-overhead/ || /processing/ || /comparison/' +RTS -N
python3 <diff_alloc.py> /tmp/old.csv /tmp/new.csv   # print old, new, delta% per leaf
```

### Correctness guards after any metrics/finalize/tracing edit

```bash
cabal test shibuya-core-test
PS=$(find dist-newstyle -type f -path '*x/prod-stress*' -name prod-stress)
"$PS" 60 8 2000 +RTS -N -T -A32m   # expect: total processed=960000, nested-atomically crashes=0
```


## Validation and Acceptance

Validated by measured allocation and preserved behavior, not compilation:

1. **Attributed (M1):** this plan states the per-message byte delta split by cause (metrics /
   finalize / tracing args), summing to ~the S1 delta.
2. **Reduced or accepted (M3):** either a candidate shows a real Allocated drop on
   `handler-overhead`/`processing`/`comparison` vs `v0.7.1.0` **with every observable value
   unchanged**, or the Decision Log records acceptance with a code comment.
3. **Semantics preserved:** `cabal test shibuya-core-test` fully green (metrics sampled values,
   `processed`/`failed` counts, in-flight max, halt, ordering, exactly-once finalization all
   unchanged), and `prod-stress` reports correct totals and zero nested `atomically`.
4. **No collateral regression:** the full suite vs `v0.7.1.0` shows the intended change on the
   shared leaves, flat elsewhere, and **no** regression on the EP-30 concurrency leaves.


## Idempotence and Recovery

All steps are safe to repeat. Benchmark/scratch builds go to `dist-newstyle` and do not alter
source unless you edit it; any measurement stub must be reverted before M2's real changes. Recover
a clean tree with:

```bash
git checkout -- shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs \
                shibuya-core/src/Shibuya/Core/Metrics.hs \
                shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs \
                shibuya-core/src/Shibuya/Telemetry/Effect.hs
git status --porcelain
```

The `git worktree` baseline is disposable: `git worktree remove --force /tmp/wt-0710`. Benchmark
timing is noisy — always compare the **Allocated** column on a quiescent machine.

Every commit for this plan must carry the trailer:

```text
ExecPlan: docs/plans/31-investigate-and-reduce-the-shared-per-message-metrics-tracing-finalize-allocation-regression.md
```


## Interfaces and Dependencies

- `Shibuya.Core.Metrics` — `beginProcessing`, `finishProcessing`, `finishFinalizationFailure`,
  `sampleMetrics`, `MetricsHandle`. Any reduction must keep `sampleMetrics` returning identical
  values (processed/failed counts, in-flight current/max, state).
- `Shibuya.Internal.Runner.Finalize` — `finalizeWithRetry`. Must keep the exactly-once
  finalization and bounded-retry behavior; only the successful-first-try allocation may shrink.
- `Shibuya.Telemetry.Effect` — `Tracing`, `runTracingNoop`, `addAttribute`, `addAttributes`,
  `addEvent`, `setStatus`, `withSpan'`, `mkEvent`. A real tracer must still observe identical
  spans/events/attributes; only the no-op case may skip argument construction.
- `shibuya-core-bench` (`Bench.Framework`, `Bench.Handler`) and `prod-stress` — measurement and
  correctness harnesses.

At the end of this plan the public signatures of `runSupervised`, `runWithMetrics`,
`processOne` (internal), and the metrics sampling API are **unchanged** unless a change is recorded
here and in the Decision Log with rationale.
