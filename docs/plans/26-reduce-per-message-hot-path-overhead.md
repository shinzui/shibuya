---
id: 26
slug: reduce-per-message-hot-path-overhead
title: "Reduce per-message hot-path overhead"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Reduce per-message hot-path overhead

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-26 under the master plan at
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`.

**Hard dependencies: EP-22 (`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md`) and
EP-23 (`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`) must be Complete before
this plan starts.** Both plans restructure the same regions of
`shibuya-core/src/Shibuya/Runner/Supervised.hs` and `shibuya-core/src/Shibuya/Runner/Batcher.hs` that
this plan edits. All line numbers cited below were taken from the tree at commit `bdfccae`
(before EP-22/EP-23 landed); before making any edit, re-locate the cited code by searching for the
quoted function names and expressions, and prefer the post-EP-22/23 shape of the code wherever they
conflict with an excerpt shown here. In particular EP-23 changes the handler-exception path in
`processOne` (it finalizes with `AckRetry (RetryDelay 0)` on exception) and may restructure the batch
scheduler; this plan's metrics changes must be applied to that final shape.


## Purpose / Big Picture

Shibuya is a queue-processing framework: an adapter produces a stream of messages, an ingester pushes
them into a bounded inbox, and a processor loop runs a user handler on each message, recording metrics
and OpenTelemetry tracing data along the way. Today, every single message pays for three separate STM
transactions on one shared `TVar ProcessorMetrics` (one in the ingester for the `received` count, one
to increment the in-flight count before the handler, one to decrement it and bump `processed`/`failed`
after), plus two `getCurrentTime` system calls whose only purpose is to refresh a timestamp inside the
`Processing` state. Under `Async n` concurrency, all n worker threads *and* the ingester serialize on
that one `TVar`; STM resolves the conflicts by retrying transactions, so adding workers adds retry
work instead of throughput. The existing benchmark suite even carries a warning comment about this
("CPU-bound handlers may cause STM blocking" in
`shibuya-core-bench/bench/Bench/Concurrency.hs`). On top of that, the disabled-tracing path allocates
a fresh dummy span, a fresh attribute `HashMap`, and a fresh event record for every message even
though all of them are constants.

After this plan, the hot counters (`received`, `dropped`, `processed`, `failed`, in-flight) live in
lock-free fetch-and-add atomic counters (from the `atomic-primops` package, already in the project's
dependency closure), the shared `TVar` is only touched on rare state *transitions* (idle→processing,
failure, halt), the constant tracing values are allocated once instead of per message, and the
parallel stream compositions carry an explicit thread bound. The observable result: the throughput
benchmark added in Milestone 0 (mock adapter, no-op handler, Serial and Async 8, tracing disabled)
shows a measurable improvement from Milestone 1 onward, while every metrics assertion in the existing
test suite — exact `received`/`processed`/`failed` totals, in-flight visibility mid-run, `Idle`/`Failed`
final states, batch conservation properties — still passes unchanged in meaning.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-02: Verified EP-22 and EP-23 are marked Complete in the master plan registry; re-located the current post-EP-22/23 code regions before starting M0.
- [x] 2026-07-02: M0: added `Bench.HotPath` module to `shibuya-core-bench` (no-op handler, mock list adapter, Serial and Async 8, 10k messages, tracing disabled).
- [x] 2026-07-02: M0: ran the benchmark and pasted baseline numbers into this plan's evidence block.
- [x] 2026-07-02: M1: added `atomic-primops` to `shibuya-core.cabal`; introduced `HotCounters`/`MetricsHandle`/`sampleMetrics` in `Shibuya.Core.Metrics`.
- [x] 2026-07-02: M1: rewrote `runIngesterWithMetrics`, `processOne`, and the batch-path metrics sites to use counters; normal completions no longer write the cold metrics `TVar`.
- [x] 2026-07-02: M1: threaded `MetricsHandle` through `Supervised.hs`, `Master.hs`, `BatchProcessor.hs`, and updated tests that read `sp.metrics` directly.
- [x] 2026-07-02: M1: `cabal build all` and `cabal test shibuya-core-test` passed; benchmark re-run and before/after numbers recorded.
- [ ] M2: dummy span becomes a top-level constant; "zero overhead" Haddock softened; constant span attributes and the handler-started event hoisted out of the per-message path.
- [ ] M2: tests green; tracing-disabled benchmark re-run; numbers recorded.
- [ ] M3: `stepArrival` single-traversal via `Map.alterF`; batcher emit path restructured so no lock is held across a blocking queue write; batch timeout ticks moved to the monotonic clock.
- [ ] M3: `maxThreads` added to both `parMapM` compositions; `BatchProcessor` decision double-lookup removed; `getAllMetricsIO`/`getProcessorMetricsIO` read TVars directly.
- [ ] M3: tests green; benchmark re-run; numbers recorded; master plan progress boxes for EP-26 ticked.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-02: The M0 no-op benchmark confirms the expected contention signature before any metrics
  changes: `async8-noop-10000` is much slower than Serial even though the handler only returns
  `AckOk`. Evidence:

  ```text
  serial-noop-10000: 14.5 ms ± 970 μs
  async8-noop-10000: 155 ms ± 14 ms
  ```

- 2026-07-02: M1 improved `serial-noop-10000` and reduced allocation, but did not improve the
  no-op `Async 8` benchmark. The first M1 implementation still wrote the cold metrics state on every
  normal completion and produced `async8-noop-10000: 173 ms ± 8.3 ms`; after removing normal
  completion cold-state writes the final M1 run was still slower than M0 at `164 ms ± 4.9 ms`.
  This indicates the no-op Async benchmark is dominated by stream scheduler/concurrency overhead as
  well as metrics contention. Evidence:

  ```text
  M0 serial-noop-10000: 14.5 ms ± 970 μs, 30 MB allocated
  M1 serial-noop-10000: 11.8 ms ± 578 μs, 21 MB allocated
  M0 async8-noop-10000: 155 ms ± 14 ms, 71 MB allocated
  M1 async8-noop-10000: 164 ms ± 4.9 ms, 64 MB allocated
  ```


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `Data.Atomics.Counter` from the `atomic-primops` package for the hot counters, rather
  than the `atomic-counters` package or a hand-rolled `fetchAddIntArray#` on a `MutableByteArray#`.
  Rationale: inspection of `dist-newstyle/cache/plan.json` shows `atomic-primops` (and `primitive`)
  are already in the project's 236-package build closure, so adding it as a direct dependency of
  `shibuya-core` downloads nothing new; `atomic-counters` is not in the closure; hand-rolling
  duplicates exactly what `atomic-primops` already wraps (a single-cell mutable byte array with
  `fetchAddIntArray#`) with no measurable gain and more unsafe code to maintain.
  Date: 2026-07-01

- Decision: Keep `ProcessorMetrics` (and its JSON instances) unchanged as the *read-side snapshot*
  type; introduce a new write-side `MetricsHandle` (atomic counters + a cold `TVar` for rare state)
  and a `sampleMetrics :: MetricsHandle -> IO ProcessorMetrics` that assembles the snapshot on read.
  Rationale: `shibuya-metrics` (Prometheus/JSON/WebSocket/Health modules) and all tests consume
  `ProcessorMetrics`/`MetricsMap` by value; keeping the snapshot type stable confines the change to
  the producers and the `Master` registry, and `getAllMetricsIO`'s signature does not change.
  Date: 2026-07-01

- Decision: The `Processing` state's timestamp now means "when the current processing burst began"
  (set only on the idle→processing transition, i.e. when the in-flight counter goes 0→1) instead of
  "when the most recent message started". A transient `Failed` state (from a handler exception) is
  cleared on the *next* idle→processing transition rather than at the start of every message.
  Rationale: this is what eliminates the two per-message `getCurrentTime` calls and the per-message
  state write. No existing test asserts the timestamp's value or the flap-back-to-Processing
  behavior — tests only pattern-match on the constructor and read `inFlight`/`maxConcurrency`
  (enumerated in Context below). If a test proves sensitive, the fallback is a cheap conditional
  per-message clear (read an `IORef`, write only when a failure flag is set); record that in
  Surprises if needed.
  Date: 2026-07-01

- Decision: Extend the existing `shibuya-core-bench` package with a new `Bench.HotPath` module
  instead of creating a new benchmark package.
  Rationale: `shibuya-core-bench` already exists (tasty-bench, `-threaded -with-rtsopts=-N`, wired
  into `cabal.project` with `benchmarks: True`), but none of its groups measure a *no-op* handler
  through `runSupervised` under `Async` — the existing `Concurrency` group only exercises Async with
  IO-bound (threadDelay) handlers, which hides the STM contention this plan removes.
  Date: 2026-07-01

- Decision: Restructure the batcher's emit path as a single `TVar` holding the batcher state plus a
  pending-output `Seq`, with admission control ("retry until pending length < capacity") at the start
  of each step transaction — rather than (a) keeping the `MVar` held across the blocking
  `writeTBQueue`, or (b) folding state + queue writes into one STM transaction over the existing
  `TBQueue`.
  Rationale: (a) holds a lock across a potentially indefinite block, stalling the ticker and creating
  an async-exception hazard; (b) deadlocks whenever one step emits more batches than the queue's
  remaining capacity (`stepTick`/`stepFlush` can emit many batches at once, and the transaction could
  then never commit). The chosen design keeps backpressure (bounded up to capacity plus one step's
  burst, documented), removes the lock entirely, and makes state transition + hand-off atomic, which
  preserves the no-double-emit and ordering guarantees the `MVar` provided.
  Date: 2026-07-01

- Decision: `getAllMetricsIO`/`getProcessorMetricsIO` (and their `Eff` wrappers) read the master's
  registry `TVar` directly and sample; the `Master` inbox message protocol keeps
  `RegisterProcessor`/`UnregisterProcessor`/`Shutdown` (registration is rare and benefits from
  serialization; `Shutdown` is inherently a control message) and drops the two `Get*` messages.
  Rationale: metrics reads are the frequent operation (the `shibuya-metrics` health endpoint even
  wraps `getAllMetricsIO` in a `timeout` to defend against the actor round-trip); the data already
  lives in TVars inside `MasterState`, so the round-trip through the inbox buys nothing.
  Date: 2026-07-01

- Decision: Batch timeout bookkeeping switches from `UTCTime`/`diffUTCTime` to monotonic nanoseconds
  (`GHC.Clock.getMonotonicTimeNSec :: IO Word64`, in `base`). The pure core's time parameter changes
  type from `UTCTime` to `Word64`.
  Rationale: `getMonotonicTimeNSec` is a cheap clock read with no calendar conversion or allocation,
  and a monotonic clock is immune to wall-clock jumps (NTP steps) that could fire or starve timeouts.
  The pure core (`stepArrival`/`stepTick`) already takes "now" as an argument, so determinism and the
  property tests are preserved by changing the argument type; nothing user-visible carries the
  timestamp (`BatchInfo` has no time field).
  Date: 2026-07-01

- Decision: Scope excludes any change to the *meaning* of the counters, to `ProcessorMetrics`'s JSON
  encoding, to the `shibuya-metrics` package, and to adapter repositories. Also excluded: hoisting
  the per-batch constant attributes in `BatchProcessor.hs` is done opportunistically in M2 only if
  trivial (batches are orders of magnitude rarer than messages; it is not on the hot path).
  Date: 2026-07-01

- Decision: In M1, normal message completion decrements the atomic in-flight counter but does not
  write `Idle` back to the cold metrics `TVar`. `sampleMetrics` reports `Idle` whenever the sampled
  in-flight counter is zero, regardless of the cold state.
  Rationale: The initial counter implementation preserved behavior but still wrote the cold `TVar`
  on every fast no-op completion, which kept a per-message synchronization point in the benchmark.
  Deriving Idle from the sampled counter preserves all observable metrics assertions while keeping
  normal completion off the cold-state path.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) contains the `shibuya-core`
library, a `shibuya-metrics` companion (HTTP/Prometheus/WebSocket exposure of metrics), a
`shibuya-example` app, and a `shibuya-core-bench` tasty-bench benchmark package. Build everything
with `cabal build all`, run tests with `cabal test shibuya-core-test`, run benchmarks with
`cabal bench shibuya-core-bench`, format with `nix fmt` (a pre-commit hook rejects unformatted
files). All commands run from the repository root.

Definitions used throughout:

- *STM* (software transactional memory): GHC's `atomically`/`TVar` mechanism. A transaction that
  touches a `TVar` another thread modified concurrently is rolled back and retried. This retry-based
  conflict resolution is exactly why one shared `TVar` updated by every worker becomes a serial
  bottleneck.
- *Fetch-and-add atomic counter*: a single machine word updated with a lock-free CPU instruction
  (`fetchAddIntArray#` under the hood). `Data.Atomics.Counter` in the `atomic-primops` package
  provides `AtomicCounter`, `newCounter :: Int -> IO AtomicCounter`,
  `incrCounter :: Int -> AtomicCounter -> IO Int` (returns the *new* value, accepts negative
  increments), and `readCounter :: AtomicCounter -> IO Int`. No transactions, no retries.
- *CAF* (constant applicative form): a top-level Haskell binding with no arguments. GHC allocates it
  once and shares it forever — the standard way to make a constant value allocation-free per use.
- *Hot path*: the code executed once per message (or once per batch): the ingester's per-message
  lambda, `processOne`, the batcher's `stepArrival`, and `processOneBatch`'s per-message finalize loop.

The message flow and the files this plan touches:

- `shibuya-core/src/Shibuya/Runner/Ingester.hs` — `runIngesterWithMetrics` (lines 48–60) runs
  `atomically $ modifyTVar' metricsVar (\m -> m {stats = incReceived m.stats})` for every message
  before sending it to the inbox. One STM transaction per message on the shared `TVar`.
- `shibuya-core/src/Shibuya/Runner/Supervised.hs` — `processOne` (around lines 531–634) is the
  single-message hot path. Per message it: builds a `frameworkAttrs` `HashMap` from scratch (lines
  ~556–567) even though three of its four entries (`messaging.system` = "shibuya",
  `messaging.destination.name` = the processor id, `messaging.operation` = "process") are constant
  for the processor's lifetime; calls `getCurrentTime` and runs an STM transaction to increment the
  in-flight count and stamp the `Processing` state (lines ~571–581); allocates
  `mkEvent eventHandlerStarted []` (line ~587) which is a constant; and after the handler calls
  `getCurrentTime` again plus a second STM transaction (`decrementAndUpdate`, lines ~628–629 and
  651–677) to decrement in-flight and bump `processed`/`failed`. `processUntilDrained` (lines
  ~469–505) composes the concurrent modes with `StreamP.parMapM (StreamP.maxBuffer n)` (Async) and
  `StreamP.parMapM (StreamP.maxBuffer n . StreamP.ordered True)` (Ahead) — with **no**
  `StreamP.maxThreads`; streamly's default thread limit is 1500 and its dispatcher treats the
  buffer-based bound as approximate, so the worker count is not actually pinned to `n`.
- `shibuya-core/src/Shibuya/Runner/Metrics.hs` — defines `ProcessorMetrics` (a record of
  `ProcessorState`, `StreamStats {received, dropped, processed, failed}`, `BatchStats`, `startedAt`,
  all with To/FromJSON), the `Processing !InFlightInfo !UTCTime` state constructor, and the pure
  `inc*` helpers. `MetricsMap = Map ProcessorId ProcessorMetrics` is the snapshot type consumed by
  `shibuya-metrics`.
- `shibuya-core/src/Shibuya/Telemetry/Effect.hs` — `withSpan'` (lines ~154–169): when tracing is
  disabled it calls `liftIO mkDummySpan` *per message*; `mkDummySpan` (lines ~294–312) rebuilds two
  `ByteString`s and a `SpanContext` on every call yet is observably pure (`OTel.wrapSpanContext` is a
  pure function; the `IO` wrapper is needless). The Haddock on `runTracingNoop` (line ~98) claims
  "zero overhead", which is false while the disabled path still allocates.
- `shibuya-core/src/Shibuya/Runner/Batcher.hs` — `stepArrival` (lines ~104–128) does a `Map.lookup`
  followed by a separate `Map.insert`/`Map.delete` (two traversals of the key); `emitStep` (lines
  ~156–164) holds an `MVar` across `atomically (writeTBQueue outQ)`, which blocks indefinitely when
  the bounded queue is full — while holding the lock the timeout ticker needs; `onArrival` (line
  ~193–195) and `tickerLoop` call `getCurrentTime` (wall clock) per arrival/tick to drive timeouts.
- `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` — `processOneBatch` resolves each retained
  message's decision with `Map.findWithDefault ... resolvedAck.decisions` (lines ~199–210) and then,
  to compute `overrideFailures`, looks the *same* message ids up in the *same* map a second time
  (lines ~224–229). It also runs the same per-batch in-flight STM increment with `getCurrentTime`
  (lines ~164–177) — per *batch*, so cheaper, but it should reuse the M1 machinery.
- `shibuya-core/src/Shibuya/Runner/Master.hs` — `MasterState.metrics` is a
  `TVar (Map ProcessorId (TVar ProcessorMetrics))`; the data is directly readable, yet
  `getAllMetricsIO`/`getProcessorMetricsIO` (lines ~165–182) send a `GetAllMetrics` message through
  the master's NQE inbox and wait for the reply — an actor round-trip per read.
- `shibuya-core-bench/` — existing tasty-bench package (`bench/Main.hs` registers `Bench.Baseline`,
  `Bench.Framework`, `Bench.Handler`, `Bench.Concurrency`). It has no no-op-handler benchmark through
  `runSupervised` under Async; M0 adds one.

**Metrics semantics the tests pin down (must remain true after every milestone).** These are the
observable behaviors; enumerate against them when reviewing any metrics change:

1. `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` (~lines 96–99): after a finite 3-message run
   with an always-`AckOk` handler, the final snapshot has `stats.received == 3`,
   `stats.processed == 3`, `stats.failed == 0`, and `state == Idle`.
2. Same file (~line 116): with a handler that throws on all 3 messages, `stats.failed == 3`.
3. Same file (~lines 180–182 and ~575–577): after `AckHalt` (and after a handler-exception run whose
   failure is last), the final `state` pattern-matches `Failed`.
4. Same file (~lines 428–455): sampling `sp.metrics` *mid-run* under `Async 3` with slow handlers
   observes `state` as `Processing info _` with `info.inFlight >= 2` at least once.
5. Same file (~lines 457–481): mid-run under `Ahead 7`, `Processing info _` has
   `info.maxConcurrency == 7`.
6. `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs` (~lines 84–89, 130–131): batch runs
   assert exact `batch.batchesEmitted`, `batch.partialFailures`, `stats.processed`, `stats.failed`.
7. `shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs` (~line 236): the property
   `metrics.stats.processed + metrics.stats.failed == msgCount` (conservation) over randomized
   schedules; (~lines 311–312) exact `failed == 2`, `processed == 3` counts.
8. Decision-to-counter mapping (from `decrementAndUpdate` and `perMsgStat`): `AckOk`/`AckRetry`
   count `processed`; `AckDeadLetter` and handler exceptions count `failed`; `AckHalt` counts
   neither but sets `Failed` state; on the batch path a thrown batch handler counts *every* message
   `failed`. Do not change this mapping.

The tests read metrics two ways: through `getMetrics`/`getAllMetrics` and by `readTVarIO sp.metrics`
directly. M1 changes the `SupervisedProcessor.metrics` field's type, so the direct reads in tests and
benches get a one-line update to the sampling call — the *values* they assert stay identical.


## Plan of Work

The work is four milestones. M0 makes the improvement measurable before anything changes. M1 is the
major fix (atomic counters). M2 and M3 are independent minor fixes grouped by verification style
(M2: tracing-disabled allocations, verified by the same benchmark; M3: batcher/scheduler/master
micro-fixes, verified by tests plus the benchmark). Commit at the end of each milestone with a
conventional-commit message carrying both trailers:

```text
MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/26-reduce-per-message-hot-path-overhead.md
```


### Milestone 0: Hot-path throughput benchmark baseline

Scope: a benchmark that isolates the framework's per-message overhead so every later milestone has a
before/after number. The repository already has `shibuya-core-bench` (tasty-bench); what it lacks is
a *no-op-handler* run through the supervised path under `Async` — precisely the configuration where
the shared-`TVar` contention dominates. At the end of this milestone a new `Bench.HotPath` group
exists and its baseline numbers are pasted into this plan.

Create `shibuya-core-bench/bench/Bench/HotPath.hs` exporting `benchmarks :: Benchmark`. Model it on
the existing `shibuya-core-bench/bench/Bench/Concurrency.hs` (copy its `createIngestedMessages`,
`Adapter` construction with `Stream.fromList`, `startMaster IgnoreAll`/`runSupervised`/`waitForDone`/
`stopMaster` driver, and its `BenchMessage` type), but with a handler that does *nothing* except
bump an `IORef` counter and return `AckOk` (no `threadDelay` — the point is to expose framework
overhead, not to simulate IO). Benchmark two configurations over 10,000 pre-created messages, with
tracing disabled via `runTracingNoop` (as the existing benches do):

- `hot-path/serial-noop-10000` — `Serial` through `runSupervised` (not `runWithMetrics`, so the
  ingester runs concurrently with the processor and the ingester's `received` update contends
  realistically).
- `hot-path/async8-noop-10000` — `Async 8` through `runSupervised`.

Use an inbox size of 1000 (a realistic bounded inbox, forcing ingester/processor interleaving).
Register the module in `shibuya-core-bench/bench/Main.hs` (`import Bench.HotPath qualified as
HotPath`, add `HotPath.benchmarks` to the `defaultMain` list) and add `Bench.HotPath` to
`other-modules` in `shibuya-core-bench/shibuya-core-bench.cabal`.

Run it and record the baseline (see Concrete Steps). Acceptance: `cabal bench shibuya-core-bench
--benchmark-options='-p "hot-path"'` completes, both benchmarks report a time, and the numbers are
recorded in the evidence block below. Note: if `Async 8` with a no-op handler stalls or is wildly
slower than Serial at baseline, that is itself evidence of the contention this plan fixes — record
it in Surprises & Discoveries, do not "fix" the benchmark to hide it.

Baseline evidence (run on 2026-07-02 with the benchmark binary's Cabal-configured `-with-rtsopts=-N`):

```text
All
  hot-path
    serial-noop-10000: OK
      14.5 ms ± 970 μs,  30 MB allocated, 3.4 KB copied, 341 MB peak memory
    async8-noop-10000: OK
      155  ms ±  14 ms,  71 MB allocated, 807 KB copied, 343 MB peak memory

All 2 tests passed (2.83s)
```


### Milestone 1: Atomic hot counters and transition-only state updates

Scope: eliminate the three per-message STM transactions and the two per-message `getCurrentTime`
calls. At the end of this milestone, the per-message path performs only fetch-and-add operations on
lock-free counters; the shared `TVar` is written only on state transitions (idle→processing burst
start, failure, halt, batch-stat updates); every metrics test still passes with identical asserted
values; and the M0 benchmark shows the delta.

First, add `atomic-primops ^>=0.8` to the `build-depends` of the `library` stanza in
`shibuya-core/shibuya-core.cabal` (check the version available in the package set with
`cabal build shibuya-core` after adding; relax the bound if the solver picks a different major
version — `atomic-primops` is already in the build closure so this costs nothing).

In `shibuya-core/src/Shibuya/Runner/Metrics.hs`, add (and export) the write-side types:

```haskell
-- | Lock-free per-message counters. Updated with fetch-and-add; never STM.
data HotCounters = HotCounters
  { received :: !AtomicCounter,
    dropped :: !AtomicCounter,
    processed :: !AtomicCounter,
    failed :: !AtomicCounter,
    inFlight :: !AtomicCounter
  }

-- | Write-side handle for one processor's metrics. 'cold' holds everything
-- that changes rarely: terminal/failed state, batch statistics, startedAt.
-- The counters hold everything that changes per message.
data MetricsHandle = MetricsHandle
  { hot :: !HotCounters,
    -- | Configured max concurrency; written once when the processing loop starts.
    maxConcurrencyRef :: !(IORef Int),
    -- | When the current processing burst began (set on 0->1 in-flight transition).
    burstStartedRef :: !(IORef UTCTime),
    -- | Rare-transition state: Idle/Failed/Stopped, batch stats, startedAt.
    cold :: !(TVar ProcessorMetrics)
  }

newMetricsHandle :: UTCTime -> IO MetricsHandle
sampleMetrics :: MetricsHandle -> IO ProcessorMetrics
```

`sampleMetrics` assembles the snapshot: read all five counters and the cold `TVar`; the returned
`stats` is `StreamStats` built from the counters; `batch` and `startedAt` come from cold; the
`state` is reconstructed as follows — if the cold state is `Failed`/`Stopped`, return it; otherwise
if the in-flight counter is > 0, return `Processing (InFlightInfo inFlightCount maxConc)
burstStarted` (from `maxConcurrencyRef`/`burstStartedRef`); otherwise `Idle`. This reconstruction is
what keeps test items 4 and 5 above true (mid-run reads see `Processing` with a live in-flight count
and the configured max concurrency) and items 1 and 3 true (final reads see `Idle`, or `Failed`
after halt/exception). The snapshot is not a single atomic cut across counters — individual counters
are each exact, and no existing test (or reasonable consumer) assumes cross-counter simultaneity;
note this in the Haddock.

Then rewrite the producers:

- `shibuya-core/src/Shibuya/Runner/Ingester.hs`: `runIngesterWithMetrics` takes the `MetricsHandle`
  (or just its `received` counter) and replaces the `atomically $ modifyTVar' ...` with
  `void $ incrCounter 1 handle.hot.received`.
- `shibuya-core/src/Shibuya/Runner/Supervised.hs`, `processOne`: replace the increment transaction
  (old lines ~571–581) with `n <- liftIO $ incrCounter 1 handle.hot.inFlight`; if `n == 1` this is
  the idle→processing transition: call `getCurrentTime`, write `burstStartedRef`, and clear a
  lingering `Failed` cold state back to `Idle` (a single cheap `atomically` that runs only on burst
  starts, not per message — and only write if the cold state actually is `Failed`, read it first
  with `readTVarIO`). Use `n` for the `attrShibuyaInflightCount` span attribute exactly as the old
  code used the post-increment value. Replace the decrement transaction (old lines ~628–629 plus
  `decrementAndUpdate`) with: `incrCounter 1` on `processed` or `failed` per the mapping in Context
  item 8 (unchanged), then `incrCounter (-1) handle.hot.inFlight`; on the rare paths (result is
  `AckHalt` or a handler error) additionally `getCurrentTime` and set the cold state to `Failed ...`
  as `decrementAndUpdate` did (respecting whatever EP-23 made this path look like — under EP-23 the
  exception path also finalizes with `AckRetry (RetryDelay 0)`; only the *metrics recording* moves
  to counters, the ack behavior is untouched). Delete `decrementAndUpdate` once nothing calls it.
  `processUntilDrained` writes `maxConcurrencyRef` once, before the loop starts.
- `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`: the per-batch in-flight increment/decrement
  uses the same counters (a batch is one in-flight unit, unchanged); `recordBatchOutcome` splits —
  per-message `processed`/`failed` totals become two fetch-and-adds with the batch's counts
  (`incrCounter processedDelta`/`incrCounter failedDelta`, computed from the resolved decisions with
  the existing `perMsgStat` mapping), while the `BatchStats` bumps and any `Failed` transition stay
  in one per-*batch* cold-`TVar` transaction (batches are rare relative to messages).
- `shibuya-core/src/Shibuya/Runner/Master.hs`: `MasterState.metrics` becomes
  `TVar (Map ProcessorId MetricsHandle)`; `RegisterProcessor` carries a `MetricsHandle`; the `Get*`
  message handlers sample with `sampleMetrics` (M3 removes the round-trip; here just keep it
  compiling and correct). `registerProcessor`'s signature changes accordingly.
- `shibuya-core/src/Shibuya/Runner/Supervised.hs`: `SupervisedProcessor.metrics` becomes
  `MetricsHandle`; `getMetrics sp = liftIO (sampleMetrics sp.metrics)`; `getProcessorState` reads via
  `sampleMetrics`. All `newTVarIO initialMetrics` sites become `newMetricsHandle now`. The
  ingester-failure paths that set `Failed` state write the cold `TVar`.

Finally update the direct readers: in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` (and any
other test found by `grep -rn "sp.metrics\|\.metrics" shibuya-core/test`), replace
`readTVarIO sp.metrics` with `sampleMetrics sp.metrics`; same in
`shibuya-core-bench/bench` if any module reads the field (as of the audit, the bench modules only
call `runSupervised`/`isDone`, but re-grep). The asserted values must not change.

Acceptance (observable): `cabal build all` succeeds; `cabal test shibuya-core-test` passes with the
same assertions as before this milestone — in particular the exact-totals tests (Context items 1, 2,
6, 7: e.g. `received == 3`, `processed == 3`, conservation `processed + failed == msgCount` under the
randomized reliability suite) prove the counters are still *exact*, not sampled approximations; the
mid-run in-flight tests (items 4, 5) prove live visibility survived; and the M0 benchmark improves —
paste before/after numbers in the evidence block. Expected direction: `async8-noop-10000` improves
the most (contention removed); `serial-noop-10000` improves moderately (five STM transactions and two
clock reads per message become a handful of fetch-and-adds).

```text
M0 baseline:
All
  hot-path
    serial-noop-10000: OK
      14.5 ms ± 970 μs,  30 MB allocated, 3.4 KB copied, 341 MB peak memory
    async8-noop-10000: OK
      155  ms ±  14 ms,  71 MB allocated, 807 KB copied, 343 MB peak memory

M1 after atomic counters:
All
  hot-path
    serial-noop-10000: OK
      11.8 ms ± 578 μs,  21 MB allocated, 3.0 KB copied, 339 MB peak memory
    async8-noop-10000: OK
      164  ms ± 4.9 ms,  64 MB allocated, 840 KB copied, 352 MB peak memory

Validation:
cabal build all: PASS
cabal test shibuya-core-test: PASS, 201 examples, 0 failures
```


### Milestone 2: Tracing-disabled allocations become constants

Scope: make the disabled-tracing path allocation-free per message and stop rebuilding constant
tracing values. At the end of this milestone, the dummy span is a shared top-level constant, the
processor-constant span attributes are computed once per processor, the handler-started event is a
top-level constant, and the "zero overhead" claim is softened to match reality.

In `shibuya-core/src/Shibuya/Telemetry/Effect.hs`:

- Replace `mkDummySpan :: IO OTel.Span` with a top-level CAF. `OTel.wrapSpanContext` is a pure
  function and every input is a constant, so the `IO` was never needed:

  ```haskell
  -- | A shared dropped span used when tracing is disabled. All operations on it
  -- are no-ops. Allocated once (CAF), so the disabled path allocates nothing per call.
  dummySpan :: OTel.Span
  dummySpan = OTel.wrapSpanContext dummySpanContext
    where ...  -- same all-zero TraceId/SpanId/SpanContext construction as mkDummySpan today
  {-# NOINLINE dummySpan #-}
  ```

  The `NOINLINE` pragma prevents GHC from inlining the definition into call sites (which would
  re-allocate it there). `withSpan'`'s disabled branch becomes `f dummySpan` — no `liftIO`.
- Soften the Haddock on `runTracingNoop` (currently "Run with tracing disabled (zero overhead).")
  to "near-zero overhead": the disabled path still branches on the enabled flag per operation; do
  not claim more than is true.

In `shibuya-core/src/Shibuya/Runner/Supervised.hs`:

- Hoist the constant attributes: in `processUntilDrained` (and `drainInboxWithMetrics`), compute once
  per processor `constAttrs = HashMap.fromList [(attrMessagingSystem, toAttribute ("shibuya" :: Text)),
  (attrMessagingDestinationName, toAttribute pidText), (attrMessagingOperation, toAttribute
  ("process" :: Text))]` and the span name `spanName = processSpanName pidText` (also a per-message
  `Text` concatenation today), and pass both to `processOne` (new parameters, or a small
  `ProcessorSpanContext` record to keep the argument list tame). Inside `processOne`, per message
  only build the two-or-three per-message entries (`attrMessagingMessageId`, optional
  `attrShibuyaPartition`) and merge preserving today's precedence exactly: framework constants,
  overlaid by per-message framework attrs, overlaid by the adapter's `envelope.attributes`
  (left-biased `HashMap.union` with the adapter map on the left, as the existing comment at old
  lines ~549–555 explains — keep that comment).
- Make the handler-started event a CAF: `handlerStartedEvent :: OTel.NewEvent;
  handlerStartedEvent = mkEvent eventHandlerStarted []` at the top level of `Supervised.hs` (with
  `NOINLINE`), used instead of the per-message `mkEvent eventHandlerStarted []`. (The completed/ack
  events carry per-message attributes and stay as they are.) If trivial after EP-23's restructuring,
  do the same for `eventBatchStarted`/`eventBatchCompleted` in
  `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`; otherwise skip — per-batch cost is not hot.

Acceptance (observable): `cabal build all`; `cabal test shibuya-core-test` passes — the telemetry
specs (`shibuya-core/test/Shibuya/Telemetry/EffectSpec.hs`, `SemanticSpec.hs`) still pass, proving
enabled-mode spans still carry the same attribute set with the same precedence; the M0 benchmark
(tracing disabled, so it exercises exactly this path) is run again and the numbers recorded. Expected
direction: a further, smaller improvement than M1 (allocation removal, not contention removal).

```text
(To be filled at M2: paste hot-path benchmark output after the change.)
```


### Milestone 3: Batcher, scheduler bounds, batch decision reuse, and master read path

Scope: the remaining micro-fixes, none of which change observable semantics. At the end of this
milestone the batcher does one Map traversal per arrival and never holds a lock across a blocking
write, batch timeouts run on the monotonic clock, both parallel stream compositions carry an explicit
thread bound, the batch processor looks each decision up once, and metrics reads no longer take an
actor round-trip.

In `shibuya-core/src/Shibuya/Runner/Batcher.hs`:

- `stepArrival`: replace the `Map.lookup` + `Map.insert`/`Map.delete` pair with a single
  `Map.alterF` traversal. `Map.alterF :: Functor f => (Maybe a -> f (Maybe a)) -> k -> Map k a ->
  f (Map k a)` lets one pass both decide the new entry and report an emission by choosing
  `f = (,) [ReadyBatch es msg]` (the pair functor accumulates the emitted batch as the first
  component). The function passed to `alterF` reproduces today's cases exactly: absent key with
  `batchSize <= 1` → emit immediately, keep absent; absent key otherwise → insert a fresh `Accum`;
  present key → grow, and if `count >= batchSize` emit and delete (return `Nothing`). The
  `BatcherSpec` property tests (message conservation, per-key order) are the safety net.
- Emit path: delete the `MVar` + `IORef` + `TBQueue` trio. Replace with a single
  `TVar (BatcherState es msg, Seq (ReadyBatch es msg))` (state plus pending output). `emitStep`
  becomes one STM transaction: read the pair; if `Seq.length pending >= capacity` then `retry`
  (admission control — this is the backpressure, and it blocks *without holding any lock*, so the
  ticker and the consumer proceed independently); otherwise run the pure step, write the new state,
  and append *all* emitted batches to `pending`. Appending the whole burst (which may transiently
  exceed `capacity` — `stepTick`/`stepFlush` can emit many batches at once) is deliberate: admitting
  the step only when below capacity keeps the buffer bounded by capacity plus one burst, while
  splitting the burst across transactions would either deadlock (a single transaction can never
  commit if the burst exceeds remaining capacity) or reintroduce a lock to keep the burst contiguous.
  Document this bound in the Haddock. `drainQueue` reads from the `Seq` side of the same `TVar`
  (pop the head, or `retry`/finish on empty+done exactly as today). Atomicity of
  state-transition-plus-hand-off in one transaction is what preserves the old `MVar`'s two
  guarantees: a size-emit and a timeout-emit for the same key cannot both fire, and batches enter
  the buffer in step order.
- Monotonic clock: change `Accum.firstArrivalAt` to `Word64` (monotonic nanoseconds), change the
  `now` parameter of `stepArrival`/`stepTick` to `Word64`, compare with
  `now - firstArrival >= timeoutNs` where `timeoutNs = round (realToFrac cfg.batchTimeout * 1e9 ::
  Double)` (compute once outside the loop), and have `onArrival`/`tickerLoop` call
  `GHC.Clock.getMonotonicTimeNSec` instead of `getCurrentTime`. Update
  `shibuya-core/test/Shibuya/Runner/BatcherSpec.hs` to feed `Word64` nows — the properties are
  time-parametric and stay deterministic. Nothing public carries this timestamp (`BatchInfo` has no
  time field), so no user-facing type changes.

In `shibuya-core/src/Shibuya/Runner/Supervised.hs`, `processUntilDrained`: add
`StreamP.maxThreads n` to both compositions —
`StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer n . StreamP.ordered True)` (Ahead) and
`StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer n)` (Async). Rationale to record in a
code comment: streamly's default `maxThreads` is 1500 and its dispatcher's buffer check is
approximate, so without the explicit bound more than `n` workers can be dispatched; `maxThreads`
pins the concurrency to what `Concurrency` promised (and what the in-flight metrics report as the
max). If EP-23/EP-24 introduced further `parMapM`/keyed-dispatch sites, apply the same bound there.

In `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`, `processOneBatch`: resolve each retained
message's decision exactly once — in the finalize loop compute
`mDecision = Map.lookup ingested.envelope.messageId resolvedAck.decisions` and
`d = fromMaybe resolvedAck.fallback mDecision`, and carry `isJust mDecision` (i.e. "the handler
explicitly named this message") in the `results` tuple. Derive `overrideFailures` from `results`
(explicitly named && `isFailing d`) instead of the second `Map.lookup` pass. The
`BatchProcessorSpec` partial-failure assertions (Context item 6) pin the behavior.

In `shibuya-core/src/Shibuya/Runner/Master.hs`: make `getAllMetricsIO` and `getProcessorMetricsIO`
read directly — `getAllMetricsIO master = readTVarIO master.state.metrics >>= traverse
sampleMetrics` and the per-processor analogue with `Map.lookup` — and route the `Eff` wrappers
(`getAllMetrics`, `getProcessorMetrics`) through them. Remove the `GetAllMetrics` and
`GetProcessorMetrics` constructors from `MasterMessage` and their `handleMessage` cases; keep
`RegisterProcessor`/`UnregisterProcessor`/`Shutdown` as messages (see Decision Log). `shibuya-metrics`
consumes only the `getAllMetricsIO`/`getProcessorMetricsIO` *functions*, whose signatures do not
change, so it keeps compiling; verify with `cabal build all` (which builds `shibuya-metrics`).

Acceptance (observable): `cabal build all`; `cabal test shibuya-core-test` fully green — in
particular `BatcherSpec` conservation/order properties, `ReliabilitySpec` (randomized schedules
through the whole batch path, including timeout-triggered emissions now on the monotonic clock), and
the `SupervisedSpec` concurrency tests (which would hang or over-parallelize if `maxThreads` were
wrong). Run the M0 benchmark once more and record the numbers (expect: no regression; the batcher
fixes don't show in the per-message benchmark but must not hurt it). Tick the two EP-26 progress
boxes in the master plan and set the registry row to Complete.

```text
(To be filled at M3: paste final hot-path benchmark output.)
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

Preflight (before M0):

```bash
grep -n "| 26 " docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
grep -n "| 22 \|| 23 " docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
```

Confirm rows 22 and 23 read `Complete`. If they do not, stop: this plan is blocked.

Per milestone, the loop is:

```bash
cabal build all
cabal test shibuya-core-test
cabal bench shibuya-core-bench --benchmark-options='-p "hot-path"'
nix fmt
git add -A && git commit
```

Expected test transcript shape (exact spec counts will differ as the suite grows):

```text
Finished in ... seconds
... examples, 0 failures
Test suite shibuya-core-test: PASS
```

Expected benchmark transcript shape (tasty-bench):

```text
All
  hot-path
    serial-noop-10000: OK
      12.3 ms ± 0.8 ms
    async8-noop-10000: OK
      9.1 ms ± 1.1 ms
```

For stabler numbers when recording evidence, prefer
`--benchmark-options='-p "hot-path" --stdev 2'` (tasty-bench keeps re-running until the standard
deviation target is met) and note the machine's capability count (the bench binary runs with
`-with-rtsopts=-N`). Paste each run into the corresponding evidence block in the milestone above.

Commit messages, one per milestone, following Conventional Commits with the two required trailers,
for example:

```text
perf(metrics): move hot-path counters to fetch-and-add atomics (EP-26 M1)

Replace the three per-message STM transactions on the shared metrics TVar
with lock-free atomic counters sampled on read; update the Processing
timestamp only on idle->processing transitions.

MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/26-reduce-per-message-hot-path-overhead.md
```

(M0: `test(bench): add hot-path no-op throughput benchmark (EP-26 M0)`; M2:
`perf(telemetry): make disabled-tracing path allocation-free (EP-26 M2)`; M3:
`perf(core): batcher single-pass alter, monotonic ticks, maxThreads, direct metrics reads (EP-26 M3)`.)


## Validation and Acceptance

The change is internal, so acceptance is demonstrated three ways:

1. Behavior preservation: `cabal test shibuya-core-test` passes at every milestone with unmodified
   *assertions* (only the mechanical `readTVarIO sp.metrics` → `sampleMetrics sp.metrics` call-site
   updates are allowed in tests). The load-bearing assertions are enumerated in Context ("Metrics
   semantics the tests pin down", items 1–8): exact totals (`received == 3`, `processed == 3`,
   `failed == 3`), mid-run `Processing` visibility with `inFlight >= 2` and `maxConcurrency == 7`,
   `Failed` after halt, batch exact counts, and the reliability suite's conservation property
   `processed + failed == msgCount` under randomized schedules. Metrics counters remain exact — the
   same totals as before under the reliability suite — because fetch-and-add never loses increments;
   only *when* the wall clock is read changed.
2. Performance: the M0 benchmark (`hot-path` group: mock adapter, no-op handler, tracing disabled)
   improves measurably at M1 — throughput under `Async 8` with a no-op handler improves, i.e. the
   `async8-noop-10000` mean time drops versus the M0 baseline beyond the runs' reported standard
   deviations — with a further drop expected at M2 and no regression at M3. The evidence blocks in
   each milestone hold the pasted tasty-bench output; a reader can reproduce with the single
   `cabal bench` command above.
3. Integration surface: `cabal build all` (which builds `shibuya-metrics` and `shibuya-example`
   against the changed core) succeeds at every milestone, demonstrating that the read-side API
   (`ProcessorMetrics`, `MetricsMap`, `getAllMetricsIO`, `getProcessorMetricsIO`) kept its shape.
   Optionally run `cabal run shibuya-example` and observe it processes its messages and prints
   metrics as before.


## Idempotence and Recovery

Every milestone is an ordinary additive code change validated by the full test suite; re-running any
build/test/bench command is always safe. Each milestone is committed separately, so `git revert` of a
single milestone commit is the rollback path. M1 is the only milestone with a wide blast radius (it
changes the `SupervisedProcessor.metrics` field type and the `Master` registry type); if it goes
sideways mid-edit, `git checkout -- shibuya-core` restores the tree to the last commit. The
benchmark numbers are environment-dependent: if a recorded run looks anomalous, re-run with
`--stdev 2` on a quiet machine rather than editing history; keep both runs in the evidence block if
they disagree, with a note. If `nix fmt` reformats files after a failed commit, re-stage
(`git add -A`) and commit again — the hook auto-formats, it does not lose work.


## Interfaces and Dependencies

New dependency: `atomic-primops` (already in the project's build closure; added as a direct
`build-depends` of the `shibuya-core` library). From it: `Data.Atomics.Counter`
(`AtomicCounter`, `newCounter`, `incrCounter`, `readCounter`). From `base`:
`GHC.Clock.getMonotonicTimeNSec :: IO Word64` (M3). No other new packages. The benchmark work uses
the existing `tasty-bench ^>=0.4` in `shibuya-core-bench`.

Signatures that must exist at the end of each milestone (full module paths):

- M0 — `Bench.HotPath.benchmarks :: Test.Tasty.Bench.Benchmark` in
  `shibuya-core-bench/bench/Bench/HotPath.hs`, registered in `bench/Main.hs`.
- M1 — in `Shibuya.Runner.Metrics`: `data HotCounters`, `data MetricsHandle`
  (fields `hot :: HotCounters`, `maxConcurrencyRef :: IORef Int`, `burstStartedRef :: IORef UTCTime`,
  `cold :: TVar ProcessorMetrics`), `newMetricsHandle :: UTCTime -> IO MetricsHandle`,
  `sampleMetrics :: MetricsHandle -> IO ProcessorMetrics`. `ProcessorMetrics`, `StreamStats`,
  `BatchStats`, `MetricsMap` unchanged. In `Shibuya.Runner.Supervised`:
  `SupervisedProcessor.metrics :: MetricsHandle`. In `Shibuya.Runner.Master`:
  `registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()`;
  `MasterState.metrics :: TVar (Map ProcessorId MetricsHandle)`. In `Shibuya.Runner.Ingester`:
  `runIngesterWithMetrics` takes the handle (or its `received` counter) instead of
  `TVar ProcessorMetrics`.
- M2 — in `Shibuya.Telemetry.Effect`: top-level `dummySpan :: OTel.Span` (with `NOINLINE`);
  `mkDummySpan` deleted; `runTracingNoop` Haddock says "near-zero". In `Shibuya.Runner.Supervised`:
  top-level `handlerStartedEvent :: OTel.NewEvent`; `processOne` receives the per-processor constant
  attributes and precomputed span name from `processUntilDrained`.
- M3 — in `Shibuya.Runner.Batcher`: `stepArrival cfg :: Word64 -> Ingested es msg -> BatcherState es
  msg -> (BatcherState es msg, [ReadyBatch es msg])` and `stepTick` likewise take `Word64` monotonic
  nanoseconds; `emitStep`'s `MVar`/`IORef`/`TBQueue` parameters replaced by the single
  `TVar (BatcherState es msg, Seq (ReadyBatch es msg))` plus a `capacity :: Natural`. In
  `Shibuya.Runner.Master`: `getAllMetricsIO :: Master -> IO MetricsMap` and
  `getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)` keep their
  signatures but read TVars directly; `MasterMessage` loses `GetAllMetrics`/`GetProcessorMetrics`.

Consumers to keep in mind (do not break): `shibuya-metrics/src/Shibuya/Metrics/{JSON,Prometheus,
WebSocket,Health}.hs` call `getAllMetricsIO`/`getProcessorMetricsIO` and pattern-match
`ProcessorMetrics`/`ProcessorState` by value; `shibuya-core-bench/bench/Bench/{Framework,
Concurrency}.hs` call `runWithMetrics`/`runSupervised`; the test suite reads
`SupervisedProcessor.metrics` directly at the sites enumerated in M1.
