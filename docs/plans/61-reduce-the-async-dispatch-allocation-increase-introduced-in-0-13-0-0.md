---
id: 61
slug: reduce-the-async-dispatch-allocation-increase-introduced-in-0-13-0-0
title: "Reduce the Async dispatch allocation increase introduced in 0.13.0.0"
kind: exec-plan
created_at: 2026-11-13T04:31:03Z
intention: "intention_01m79jrmqwempbkbvzk40cqtp0"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-13T04:31:03Z
---

# Reduce the Async dispatch allocation increase introduced in 0.13.0.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shibuya 0.13.0.0 made per-message processing cheaper on every serial path, about 208 bytes
less per message. However, processors configured with `Async n` concurrency whose handlers
wait (for example on I/O) now allocate more per run than in 0.12.0.0. With `Async 5`, the
increase is 20–30%. Time did not change, and the release accepted the increase so that the
adapters could migrate (see
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md`, Decision Log
entry of 2026-11-12). This plan finds out why the increase happens and removes as much of it
as can be removed. It must keep the serial gain, the hard limit of `n` concurrent handlers,
and the tracing behaviour 0.13.0.0 introduced.

After this plan, the `Async` benchmark cells listed under Context and Orientation allocate no
more than they did in 0.12.0.0, or the plan records, with measurements, why the remaining
difference cannot be removed. Anyone can see the result by running the benchmark comparison
in Concrete Steps against the `v0.12.0.0` tag. The fix ships in a patch or minor release
after 0.13.0.0; this plan does not publish it.


## Progress

- [ ] M1: The increase is characterized. Two things are measured: whether it is a cost per
  run, per message, or per worker thread, and which part of commit `efd1081` causes it. The
  hypotheses below are confirmed or rejected with evidence.
- [ ] M2: A change reduces `Async` allocation to within the `v0.12.0.0` range, or as far as
  the measurements allow. Serial allocation keeps the 0.13.0.0 reduction, the `n`-thread
  bound and all tests hold, and the time gate passes.
- [ ] M3: The changelog's Unreleased section, plan 55 and the MasterPlan record the outcome,
  and any durable lesson is captured in `shibuya-core-bench/README.md` or an ADR.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Investigate after releasing 0.13.0.0 rather than before.
  Rationale: The increase costs no time and affects only `Async` runners whose handlers
  wait. The adapters needed the release to start migrating. The user accepted the increase
  for 0.13.0.0 and asked for this investigation afterwards, without blocking the release.
  Date: 2026-11-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shibuya is a Haskell framework for processing messages from queues. The library is the
package `shibuya-core`; its benchmarks live in the package `shibuya-core-bench`, which uses
`tasty-bench`. Each benchmark *cell* (one leaf of the benchmark tree, such as
`concurrency-modes.concurrency-levels.async-100msgs-1ms.async-5`) reports mean time and
`Allocated`, the bytes allocated by the whole process during one run of the cell.

A *processor* reads messages from an adapter (a source of messages) into an inbox and runs a
user handler on each one. Its concurrency is a `Concurrency` value from
`shibuya-core/src/Shibuya/Policy.hs`: `Serial`, `Ahead n` (up to `n` handlers at once,
results in order) or `Async n` (up to `n` at once, unordered). Concurrent modes use
streamly's `parMapM` (from the `streamly` package's `Streamly.Data.Stream.Prelude`, imported
as `StreamP`) in `processUntilDrained` in
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`:

```haskell
(_, Async n) ->
  Stream.fold Fold.drain $
    StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer (2 * n)) processAction inboxStream
```

streamly runs `parMapM` with *worker threads*: green threads it forks on demand, which take
items from the stream, run the action, and exit when there is no more work. It forks a
worker only when both the thread limit (`maxThreads`) and the output-buffer limit
(`maxBuffer`) allow it. How often workers are forked and exit (*dispatch churn*) therefore
depends on timing, and each forked thread allocates a thread object and a stack. A comment at
that dispatch site, and
`docs/plans/30-investigate-and-reduce-the-async-ahead-concurrency-allocation-regression.md`,
record an earlier investigation of the same mechanism. There, `maxBuffer n` caused up to 90%
extra allocation, and `maxBuffer (2 * n)` removed most of it while keeping `maxThreads n`.
That plan's method and its correctness guards (below) are the starting point here.

`processAction` wraps `processOne` (same file), which runs once per message. In 0.12.0.0,
`processOne` began with:

```haskell
let parentCtx = ingested.envelope.traceContext >>= extractTraceContext
withExtractedContext parentCtx $
  withSpan' spanName consumerSpanArgs $ \traceSpan -> do ...
```

Commit `efd1081` ("feat(telemetry)!: link processing spans to their creation context",
plan `docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md`)
replaced that with `withProcessSpan correlation spanName ingested.envelope.traceContext $
\traceSpan -> do ...`, from `shibuya-core/src/Shibuya/Telemetry/Process.hs`.
`withProcessSpan` is marked `INLINE`. It checks `isTracingEnabled` first, and when tracing is
disabled it calls `withSpan' name consumerSpanArgs body` directly, without decoding headers.
It also threads a `TraceCorrelation` argument through `processUntilDrained` and `processOne`.
Every benchmark below runs with tracing disabled (`runTracingNoop` from
`shibuya-core/src/Shibuya/Telemetry/Effect.hs`), so only the disabled branch runs.

The measured increase, from the 0.13.0.0 release gate (four runs of each tree, alternating,
`+RTS -N` on a 36-core machine, load below 8). Ranges are `Allocated` bytes per run:

```text
cell                                                   v0.12.0.0              0.13.0.0
io-bound.100-msgs-1ms-delay.async-5                    1,167,888..1,208,811   1,471,957..1,572,072
io-bound.50-msgs-5ms-delay.async-5                       931,760..1,000,657   1,206,740..1,228,569
concurrency-levels.async-100msgs-1ms.async-5           1,181,146..1,274,101   1,464,403..1,512,046
concurrency-levels.async-100msgs-1ms.async-10          1,452,627..1,502,620   1,548,341..1,570,684
concurrency-levels.async-100msgs-1ms.async-20          1,782,642..1,806,708   1,834,412..1,855,974
concurrency-levels.async-100msgs-1ms.async-2           1,151,602..1,167,180   1,128,025..1,137,152
```

All names above are prefixed `concurrency-modes.`. `Ahead` cells and
`hot-path.async8-noop-10000` are flat or lower, and serial cells are 7–10% lower. The
increase for `async-5` is roughly 250–350 KB per run, and it is about the same for 100
messages as for 50. That suggests a per-run or per-worker cost rather than a per-message
one, but this has not been established. It shrinks as `n` grows, and is negative at `n = 2`.
The same cells measured at `40d112d` (the end of plan 55) and at `e09be0c` already show the
higher figures, so the cause lies in plan 55's commits (`efd1081`, with `af02ae5` touching
only benchmarks, tests and docs). The benchmark harness itself changed only to add
`telemetry = defaultAdapterTelemetry` to its `Adapter` record.

Hypotheses to test in M1, none yet confirmed:

1. Stack growth per worker. A forked thread starts with a small stack and allocates extra
   stack chunks as it grows. If the inlined `withProcessSpan` body, or its `bracket`, gives
   the per-message code a deeper stack, each worker could allocate an extra chunk, and with
   churn that is a cost per fork. That fits a per-run figure that does not scale with
   message count. Test: run the cells with a larger initial stack (`+RTS -ki16k`, or a larger
   `-kc` chunk size) on both trees. If the difference disappears, this is the cause.
2. Changed dispatch timing. A cheaper or differently shaped per-message action changes how
   often streamly forks and retires workers. Test: count forks with a debug counter, or
   compare the `GC` and thread statistics from `+RTS -s` for one cell on both trees.
3. Code shape from inlining. `INLINE` on `withProcessSpan` and the extra `correlation`
   argument change the closures built for `processAction`. Test: as a prototype on HEAD,
   restore the 0.12.0.0 shape of the disabled path (`withSpan'` directly when tracing is
   disabled, chosen once per processor), or remove `INLINE`. Then measure.

Correctness guards from plan 30, which apply to any change near the dispatch site. Run
`cabal test shibuya-core`, and run `prod-stress`, the stress executable in
`shibuya-core-bench`. It must report zero "nested atomically" crashes and the expected total.

Relevant ADRs:
[ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md)
treats an allocation increase as a regression even when time is within noise; this plan is
that rule applied after the fact.
[ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md)
fixes the disabled-tracing contract: disabled runners use one shared no-op provider and pass
a sentinel span. Any change to the disabled path must keep that.
[ADR 0014](../adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md)
defines the 0.13.0.0 correlation behaviour (links, `ParentAndLink`/`LinkOnly`, no header
decoding when disabled). The tests in
`shibuya-core/test/Shibuya/Telemetry/CorrelationSpec.hs` check it, and they must keep
passing. `shibuya-core-bench/README.md` explains how to compare benchmarks on a loaded
machine; its rules are part of this plan's method.


## Plan of Work

### Milestone 1: characterize

The goal is to know what the extra allocation is before changing anything. Build the
benchmark at `526ddb1` (the parent of `efd1081`) and at `efd1081` in two git worktrees. Run
the `concurrency-modes` group at least four times on each, alternating, and confirm the shift
is between them. If it is not, widen the range to `v0.12.0.0` and `40d112d`, and record the
change in Surprises & Discoveries. From the cells' message counts (50 and 100) and
concurrency levels (2, 5, 10, 20), work out whether the extra bytes scale per run, per
message or per `n`.

Then test the three hypotheses in order, each on both trees, recording numbers in Surprises &
Discoveries. For hypothesis 1, run the async cells with `+RTS -N -ki16k` and with
`+RTS -N -kc64k` (pass RTS options after the benchmark options). For hypothesis 2, use
`+RTS -s` on a single cell selected with `-p`, and compare the reported totals and GC counts.
For hypothesis 3, make a throwaway branch of HEAD that restores the disabled path's old shape
and measure it. Discard the prototype once its result is recorded; it is not the fix unless
M2 adopts it.

M1 is accepted when Surprises & Discoveries states the scaling and names the cause. If the
cause is not one of the three, it states what was ruled out and with what evidence.

### Milestone 2: reduce

Change `shibuya-core` to remove the cause found in M1. Likely forms, depending on the cause,
are:

- choosing a disabled-tracing specialization of `processOne` once per processor, as
  `processUntilDrained` already does for `detailed`;
- changing `withProcessSpan`'s inlining or structure so the disabled branch has the old shape;
- for stack growth, avoiding the deeper per-message stack.

Do not loosen `maxThreads n`. Do not change ordering, finalization, or halt behaviour, or the
public signatures of `withProcessSpan` and `withProcessSpanIO`. If the only remaining
remedy is a dispatch-parameter change like plan 30's, record it as a decision and apply plan
30's guards.

Accept M2 when all of the following hold, measured as in Concrete Steps:

- The six cells in the table under Context and Orientation allocate within or below their
  `v0.12.0.0` ranges.
- Serial cells (`hot-path.serial-noop-10000`, `handler-overhead`, `framework-overhead`,
  `concurrency-modes.cpu-bound-serial`) keep 0.13.0.0's allocation, to within run-to-run
  spread.
- The `tracing` group's enabled cells show no allocation increase over 0.13.0.0.
- The full benchmark passes `--fail-if-slower 10` against `v0.13.0.0`, using the
  interleaved confirming method if a sequential run fails cells the change does not touch.
- The checks below all pass.

If the cells cannot be brought within range, accept the largest safe reduction. Record the
remaining difference and why it remains in the Decision Log, and stop for the user's decision.

### Milestone 3: record

Add an entry to an "Unreleased" section at the top of `shibuya-core/CHANGELOG.md` with the
before and after figures. Add a note to plan 55's correction bullet and to the MasterPlan's
release-gate discovery pointing at this plan's result. If M1 found a mechanism future changes
can trip over again, document it. A benchmark-reading lesson, such as "check stack chunk
growth when async allocation moves without time", belongs in `shibuya-core-bench/README.md`.
A design constraint on the runner belongs in a new ADR in `docs/adr/`.


## Concrete Steps

All commands run from the repository root inside the nix devShell. The benchmark binary path
below is the one cabal produces on this machine; find it with
`find dist-newstyle -type f -perm -u+x -name shibuya-core-bench` if it differs.

Build two trees for comparison, each in its own worktree:

```bash
git worktree add --detach ../shibuya-wt-before 526ddb1
git worktree add --detach ../shibuya-wt-after efd1081
for d in ../shibuya-wt-before ../shibuya-wt-after .; do
  (cd "$d" && cabal build shibuya-core-bench:bench:shibuya-core-bench --enable-benchmarks)
done
```

Run one interleaved pair of the async cells, repeating it at least four times. Start each
pair only when `sysctl -n vm.loadavg` shows a one-minute load below 8:

```bash
B=dist-newstyle/build/aarch64-osx/ghc-9.12.4/shibuya-core-bench-0.1.0.0/b/shibuya-core-bench/build/shibuya-core-bench/shibuya-core-bench
PAT='/concurrency-modes/'
(cd ../shibuya-wt-before && ./$B -p "$PAT" --stdev 3 --timeout 120 --csv /tmp/before-1.csv)
(cd ../shibuya-wt-after  && ./$B -p "$PAT" --stdev 3 --timeout 120 --csv /tmp/after-1.csv)
```

For hypothesis 1, append RTS options to the same commands, for example
`... --csv /tmp/before-ki16k-1.csv +RTS -N -ki16k -RTS`. For hypothesis 2, use one cell:

```bash
(cd ../shibuya-wt-after && ./$B -p '$NF == "async-5" && /concurrency-levels/' --stdev 3 +RTS -N -s -RTS)
```

Compare CSVs with a small script that joins on `Name` and prints the `Allocated` difference
per cell; record min..max ranges over the runs, not single values.

Final comparison for M2, against the released tag, from a worktree at `v0.12.0.0` for the
allocation ranges and at `v0.13.0.0` for the time gate:

```bash
git worktree add --detach ../shibuya-wt-v013 v0.13.0.0
(cd ../shibuya-wt-v013 && cabal build shibuya-core-bench:bench:shibuya-core-bench --enable-benchmarks && \
  ./$B --stdev 5 --timeout 120 --csv /tmp/v013.csv)
./$B --stdev 5 --timeout 120 --baseline /tmp/v013.csv --fail-if-slower 10 --csv /tmp/candidate.csv
```

Correctness guards:

```bash
cabal test shibuya-core shibuya-metrics --enable-tests
PS=$(find dist-newstyle -type f -perm -u+x -name prod-stress | head -1)
"$PS" 60 8 2000 +RTS -N -T -A32m
```

Expected `prod-stress` tail:

```text
DONE. total processed=960000   nested-atomically crashes (any thread)=0
no nested atomically in production path across this run
```

Remove the worktrees when done with `git worktree remove ../shibuya-wt-before` (and the
others).


## Validation and Acceptance

The change is shown by allocation measured on the benchmark cells, not by compilation. Before
M2, the six `Async` cells allocate in the 0.13.0.0 ranges in the table under Context and
Orientation. After M2, four alternating runs show them within or below the `v0.12.0.0`
ranges, while the serial cells keep 0.13.0.0's lower figures.

Behaviour is unchanged. `cabal test shibuya-core` (all four suites: `shibuya-core-test`, the
two GC suites and `shibuya-core-trace-retention-test`) and `cabal test shibuya-metrics` pass.
That includes `Shibuya.Telemetry.CorrelationSpec` for the 0.13.0.0 tracing contract and the
runner specs for ordering, the concurrency bound and halt behaviour. `prod-stress` reports
zero nested-atomically crashes and 960000 processed.

The time gate passes against `v0.13.0.0` as described in M2.

Not required, and proposed only if M1 suggests it: new benchmark cells, changes to `Ahead`
dispatch, or changes to the enabled tracing path.


## Idempotence and Recovery

Measurements and worktrees can be repeated and removed freely; nothing is published.
Prototype branches for hypothesis 3 are throwaway and must not be merged. A source change in
M2 is an ordinary commit that can be reverted with git. If a candidate breaks a test or the
`prod-stress` guard, revert it and record the result in Surprises & Discoveries before
trying the next.


## Interfaces and Dependencies

The work is in `shibuya-core`: `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`
(`processUntilDrained`, `processOne`) and `shibuya-core/src/Shibuya/Telemetry/Process.hs`
(`withProcessSpan`). The public signatures of `Shibuya.Telemetry.Process.withProcessSpan`
and `withProcessSpanIO`, and `Adapter`'s `telemetry` field, must not change. Downstream
consumers depend on them: the adapters, and Keiro's planned use of `withProcessSpan`.

Dependencies whose behaviour matters: `streamly` `^>=0.11` (`parMapM`, `maxThreads`,
`maxBuffer`), whose source is located with `mori registry show composewell/streamly --full`.
Also the GHC runtime system's thread stack options (`-ki`, `-kc`), documented in the GHC
user's guide under RTS options. No new package dependency is expected.

This plan has no prerequisite beyond the released `v0.13.0.0` tag. It is not a child of a
MasterPlan, but it follows from the decision recorded in
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md` and corrects a claim
in `docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md`.
