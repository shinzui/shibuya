---
id: 29
slug: fix-nested-atomically-race-in-concurrent-ingester-processor-path
title: "Fix nested-atomically race in concurrent ingester/processor path"
kind: exec-plan
created_at: 2026-07-04T17:30:50Z
---

# Fix nested-atomically race in concurrent ingester/processor path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a follow-up to EP-22
(`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md`) under the master plan
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`.
It was opened after the 0.8.0.0 release when benchmarks were finally run for regressions and
surfaced a hard crash. All investigation described below was performed against the `master`
branch at commit `e22462a` (the 0.8.0.0 README refresh), on an Apple Silicon macOS machine
(aarch64-osx) with GHC 9.12.4 and cabal 3.16.


## Purpose / Big Picture

Shibuya is a queue-processing framework. An *adapter* produces a stream of messages; an
*ingester* pushes them into a bounded *inbox* (a mailbox with a maximum capacity, used for
backpressure); and a *processor* loop pulls from the inbox and runs a user *handler* on each
message. In version 0.8.0.0 the processor path throws a fatal runtime exception under load:

```text
Control.Concurrent.STM.atomically was nested
```

This message is raised by the GHC runtime when a thread that is **already inside** a software
transactional memory (STM) transaction (a block run by the `atomically` function) tries to
start a **second** `atomically` on the same thread. STM does not allow this, so the runtime
kills the transaction with the exception above. In shibuya this crashes a running processor.

The crash is currently observed through the benchmark suite, but the defective code is on the
**production** processing path: `runWithMetrics` (a finite-stream test/benchmark entry point)
and the supervised `runSupervised` (the real production runner) both call the same
`runIngesterAndProcessor` machinery where the fault lives. So this is a correctness bug that
can crash real consumers, not merely a benchmark artifact.

After this plan is complete, a user gains a processor path that runs the ingester and the
processor concurrently **without** ever nesting `atomically`, verified by a permanent
regression test that reproduces the crash before the fix and passes after it, plus
library-level hardening so that a future refactor cannot silently reintroduce a nested
transaction. The observable outcome: the reproduction command in "Concrete Steps" prints
`FAIL ... atomically was nested` on today's tree and prints `OK` after the fix, and
`cabal test shibuya-core-test` includes a new test that exercises the concurrent path
thousands of times without crashing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Investigation (done — 2026-07-04, before this plan file existed):

- [x] Ran benchmarks for the first time since 0.8.0.0: built and ran the `shibuya-core-bench`
      suite for both `v0.7.1.0` (pre-refactor baseline) and `master` (`e22462a`) on the same
      machine, comparing via `tasty-bench` CSV baseline.
- [x] Discovered a hard crash: `framework-overhead.processing.runWithMetrics-100` fails with
      `Control.Concurrent.STM.atomically was nested` on 0.8.0.0; the same benchmark passed on
      0.7.1.0. Reproduced 2/2 full-suite runs and ~100% under `--stdev 1` in isolation.
- [x] Confirmed the crash is a shibuya bug, not a benchmark bug: the benchmark harness
      contains zero `atomically` calls; every STM operation on the failing path is
      shibuya/NQE library code.
- [x] Localized the **inner** (nested) transaction to the per-message inbox receive in
      `inboxToStream` in `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, using a
      temporary `guardedAtomically` nesting detector and a profiled `+RTS -xc` cost-centre
      stack.
- [x] Established that the **outer** open transaction is on the same (processor) thread and is
      *not* a shibuya `atomically` — it originates below shibuya's source in the
      runtime/library STM layer under this concurrency pattern.
- [x] Found the introducing change: 0.8.0.0 (EP-22) rewrote `runWithMetrics` from a
      **sequential** ingester-then-drain shape to the **concurrent** `runIngesterAndProcessor`
      shape shared with `runSupervised`.
- [x] Measured streamly's role: replacing the Serial drain's streamly consumption with a
      hand-rolled loop dropped the crash rate from ~20/20 to 1/20 — streamly amplifies the
      race window massively but is not strictly required.
- [x] Reverted all temporary diagnostic scaffolding; the working tree is clean.

Fix work (remaining):

- [ ] M0: Add a permanent, deterministic-enough regression test that reproduces the nested
      `atomically` on today's tree (fails now).
- [ ] M1: Build a minimal standalone reproducer (no `tasty`, no streamly) to positively
      identify the outer transaction, so the fix is grounded in mechanism, not guesswork.
- [ ] M2: Write up the confirmed streamly/STM interaction in this plan's Surprises section.
- [ ] M3: Apply the fix (decouple the blocking inbox receive from the stream driver — see Plan
      of Work) and prove the reproducer/test now passes.
- [ ] M4: Add library-robustness hardening so a nested `atomically` cannot silently return
      (assertion/guard and/or a property test over Serial/Ahead/Async).
- [ ] M5: Re-run the full benchmark suite vs `v0.7.1.0`; confirm the crash is gone and record
      the separately-tracked `Async n` allocation regression (see Surprises) for follow-up.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

### S1 — The crash: `runWithMetrics-100` throws nested `atomically` on 0.8.0.0, not on 0.7.1.0

Running the benchmark leaf in isolation on `master` (`e22462a`):

```text
framework-overhead
  processing
    runWithMetrics-100: FAIL
      Exception: Control.Concurrent.STM.atomically was nested
1 out of 1 tests failed (0.02s)
```

The identical benchmark on `v0.7.1.0` passes:

```text
runWithMetrics-100:   OK
  50.9 μs ± 7.4 μs, 222 KB allocated, 11 B copied
```

It is a genuine race: in a fresh process the *first* measured invocation crashes with high
probability, but a warmed-up process rarely re-crashes (once some state is cached the window
narrows). This is why an earlier `--stdev 20` isolated run happened to pass while `--stdev 1`
crashes almost immediately.

### S2 — The benchmark is not at fault; it is a shibuya bug

`grep -rn 'atomically' shibuya-core-bench/bench/` returns nothing. The benchmark handler does
`atomicModifyIORef'` (an `IORef` update, not STM). Every `atomically` on the failing path is
shibuya or NQE code. Therefore the nesting is composed entirely from library STM calls.

### S3 — The nested (inner) transaction is the inbox receive in `inboxToStream`

A temporary detector replaced shibuya's `atomically` calls with a wrapper that (a) tracks, per
Haskell thread, whether a guarded transaction is already active, and (b) catches the runtime
"nested" error and reports the call site via `HasCallStack`. It pointed unambiguously at the
per-message inbox receive:

```text
### NESTED-ATOMICALLY (RTS threw inside this guarded atomically)
### inner site (this call):
  guardedAtomically, called at src/Shibuya/Internal/Runner/Supervised.hs:461:13
    in shibuya-core-0.8.0.0-inplace:Shibuya.Internal.Runner.Supervised
### guarded transactions currently active (all threads):
    tid#15 => (this same call)
### => the OUTER open transaction on tid#15 is NOT a guarded shibuya call
```

`Supervised.hs:461` (at commit `e22462a`) is inside `inboxToStream`:

```haskell
result <-
  atomically $
    (Just <$> receiveSTM inbox)
      `orElse` ( do
                   done <- readTVar streamDoneVar
                   empty <- mailboxEmptySTM inbox
                   if done && empty then pure Nothing else retry
               )
```

Here `receiveSTM`/`mailboxEmptySTM` are NQE's `readTBQueue`/`isEmptyTBQueue` (plain STM;
verified in the NQE source at `Control.Concurrent.NQE.Process`). The detector's map showed
**only this thread's own receive** active — meaning the outer transaction that is already open
when this receive starts is **unguarded** (a non-shibuya `atomically`) and on the **same
processor thread**.

A profiled build (`cabal build --enable-profiling --profiling-detail=late`) run with
`+RTS -xc` corroborates the inner frame and shows the surrounding harness:

```text
*** Exception (reporting due to +RTS -xc): stack trace:
  ...
  called from Shibuya.Internal.Debug.NestGuard.guardedAtomically1,
  called from Shibuya.Internal.Runner.Supervised.inboxToStream,
  called from Effectful.Internal.Unlift.persistentConcUnlift,
  called from Effectful.Internal.Monad.concUnliftIO,
  called from Effectful.Internal.Monad.runEff,
  called from Bench.Framework.benchmarks57,
  ...
  called from Test.Tasty.Parallel.actionRun,
  called from Control.Concurrent.Async.async,
  called from System.Timeout.timeout1,
  ...
```

Note the harness layers `System.Timeout.timeout` and `Control.Concurrent.Async.async` around
the benchmark — relevant to S5.

### S4 — The introducing change: `runWithMetrics` went from sequential to concurrent

In `v0.7.1.0`, `runWithMetrics` ran the ingester to completion and *then* drained, with no
concurrency:

```haskell
-- v0.7.1.0 shibuya-core/src/Shibuya/Runner/Supervised.hs
runWithMetrics inboxSize procId adapter handler = do
  ...
  inbox <- liftIO $ newBoundedInbox inboxSize
  runIngesterWithMetrics metricsVar adapter.source inbox   -- push ALL messages first
  drainInboxWithMetrics metricsVar procId handler inbox    -- then drain sequentially
  liftIO $ atomically $ writeTVar doneVar True
  ...
```

In `0.8.0.0` (the EP-22 lifecycle refactor) `runWithMetrics` was unified onto the concurrent
supervised shape (`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, `runWithMetrics`
at line ~217 → `runIngesterAndProcessor`):

```haskell
-- 0.8.0.0
runWithMetrics inboxSize procId adapter handler = do
  ...
  runIngesterAndProcessor metricsHandle procId inboxSize Unordered Serial adapter handler
    `finally` liftIO (atomically (writeTVar doneVar True))
```

`runIngesterAndProcessor` (line ~248) spawns the ingester with `UIO.withAsync` and runs the
processor concurrently via `processUntilDrained` → `inboxToStream` (the blocking STM receive).
Crucially, **`runSupervised` (line ~181) uses the exact same `runIngesterAndProcessor`**, so
the defect is on the production path, not only the test helper. The Serial dispatch in
`processUntilDrained` (`Stream.fold Fold.drain $ Stream.mapM processAction inboxStream`) is
byte-identical between 0.7.1.0 and 0.8.0.0; what changed is that `runWithMetrics` now drives
it concurrently with a live ingester sharing the inbox.

Why the change was made (from EP-22 and the code comment): to give `runWithMetrics` "the same
concurrent ingester/drainer shape as the supervised runner," so tests exercise the real
production lifecycle instead of a divergent sequential shortcut. The intent was sound; it
inadvertently exposed a latent nesting hazard in the concurrent receive path (which
`runSupervised` presumably shared already but which no benchmark/test had hammered under a
threaded harness).

### S5 — Reproduction requires the threaded harness; streamly amplifies it ~20×

A standalone reproducer that calls `runWithMetrics` (100 messages, no-op handler) directly in
a tight loop of 200,000 iterations — and again as 8 concurrent workers × 20,000 — **never**
reproduced the crash. The benchmark trips it on the *first* call. The difference is the
harness: `tasty` runs the benchmark action inside `System.Timeout.timeout` and
`Control.Concurrent.Async.async` (see the S3 stack), i.e. on a forked, timed, masked thread.
The plain loop on the main thread lacks that context.

Streamly is a strong amplifier but not the root. Replacing the Serial branch's streamly
consumption (`Stream.fold Fold.drain $ Stream.mapM processAction inboxStream`) with a
hand-rolled recursive loop performing the same `atomically (receiveSTM orElse …)` receive and
the same `processAction` — no streamly — dropped the reproduction rate from ~20/20 attempts to
**1/20**. So the nesting is fundamental to the concurrent blocking-receive pattern; streamly's
stream driver widens the window enormously (the leading hypothesis is that the streamly step
that pulls the next element is being entered while the runtime still considers a transaction
open, but this must be confirmed in M1/M2 — see Open Questions).

### S6 — Separate, non-fatal regression: `Async n` allocation up ~87%

While benchmarking, allocation (a deterministic signal, unlike noisy timing) rose across the
board and sharply for async concurrency. The concurrency dispatch in `processUntilDrained`
changed only by adding `StreamP.maxThreads n`:

```diff
-  StreamP.parMapM (StreamP.maxBuffer n) processAction inboxStream                 -- 0.7.1.0
+  StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer n) processAction …    -- 0.8.0.0 (EP-26 M3)
```

Deterministic allocation deltas (v0.7.1.0 → master) for `concurrency-levels.async-100msgs-1ms`:
`async-10` +86.8% (1.40 MB → 2.62 MB), `async-20` +47.2%, `async-5` +38.7%, `ahead-5` +16.5%,
with wall-time essentially unchanged. This was a deliberate correctness change in EP-26 M3
("configured concurrency is now a hard streamly thread bound"), but it was never benchmarked
against 0.7.1.0, so the allocation cost went unrecorded. This is tracked here as a related
follow-up, **not** part of the crash fix (M5).

### Open Questions (to resolve in M1/M2)

1. What exactly is the outer, unguarded `atomically` on the processor thread? Candidates that
   remain: (a) an STM operation inside `unliftio`/`async`'s `withAsync`/`waitCatch`
   coordination composed onto the processor thread; (b) a streamly-internal transaction in the
   concurrent channel that leaks onto the serial path via shared state; (c) a lazily-forced
   thunk that, when evaluated inside the receive transaction, itself runs `atomically`. No
   `unsafeIOToSTM` exists in shibuya or NQE, so a hidden IO-in-STM in a dependency is possible
   but unconfirmed.
2. Does `runSupervised` (Serial/Ahead/Async) crash the same way under a threaded harness? The
   `Concurrency` benchmark uses `runSupervised` but its `io-bound` cases time out and were
   inconclusive. M1 must test `runSupervised` directly.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat this as a production-path correctness bug, not a benchmark/test-only issue.
  Rationale: `runWithMetrics` and `runSupervised` share `runIngesterAndProcessor`, where the
  nesting occurs; the benchmark is merely the first workload to exercise it under a threaded
  harness. Date: 2026-07-04.

- Decision: Do not ship a fix based only on static reasoning; first build a minimal reproducer
  that positively identifies the outer transaction (M1). Rationale: exhaustive static analysis
  of shibuya + NQE + effectful found no visibly-nested `atomically`; the nesting is emergent,
  so a fix must be validated empirically or it risks being a band-aid. Date: 2026-07-04.

- Decision: Keep the `Async n` allocation regression (S6) out of the crash fix and track it as
  a separate milestone (M5) / follow-up. Rationale: it is a deliberate, non-fatal tradeoff from
  EP-26 M3; conflating it with a crash fix would muddy the change and its verification.
  Date: 2026-07-04.

- Decision: Reverted all temporary diagnostic scaffolding (the `NestGuard` module, the
  `guardedAtomically` substitutions, the hand-rolled Serial loop, the standalone reproducer,
  and the `async` bench dependency) rather than leaving it in the tree. Rationale: the tree
  must stay clean and buildable between sessions; the scaffolding is reconstructable from this
  plan's Concrete Steps. Date: 2026-07-04.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything relevant lives in the `shibuya-core` package. Read these files before editing:

- `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` — the runner. Key functions:
  - `runSupervised` (production runner under NQE supervision) and `runWithMetrics` (finite,
    standalone runner used by tests/benchmarks). Both call `runIngesterAndProcessor`.
  - `runIngesterAndProcessor` — spawns the ingester with `UIO.withAsync` (from `unliftio`) and
    runs the processor concurrently via `processUntilDrained`.
  - `inboxToStream` — turns the bounded inbox into a `Streamly.Data.Stream.Stream IO` by
    repeatedly running `atomically ((Just <$> receiveSTM inbox) orElse (…retry…))`. **This is
    where the nested transaction is detected (the inner site).**
  - `processUntilDrained` — pattern-matches `(ordering, concurrency)`. For `Serial` it runs
    `Stream.fold Fold.drain $ Stream.mapM processAction inboxStream`; for `Ahead`/`Async` it
    uses `StreamP.parMapM …`. `processAction = runInIO . processOne …`.
- `shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs` — `runIngesterWithMetrics`: reads the
  adapter stream and `send`s each message into the inbox (`send = atomically . sendSTM`).
- `shibuya-core/src/Shibuya/Core/Metrics.hs` — `beginProcessing`/`finishProcessing`. Hot
  counters are lock-free (`atomic-primops`); a cold `TVar ProcessorMetrics` is written under
  `atomically` only on state transitions (idle→processing, failure, halt).
- Dependency sources on disk (found via `mori`; do not read `/nix/store`):
  - NQE: `/Users/shinzui/Keikaku/hub/haskell/nqe` (mailbox = `TBQueue`; `receiveSTM`/`sendSTM`/
    `mailboxEmptySTM` are plain STM).
  - effectful: `/Users/shinzui/Keikaku/hub/haskell/effectful-project` (the `ConcUnlift`
    persistent/ephemeral unlift is MVar-based, not STM — see
    `effectful-core/src/Effectful/Internal/Unlift.hs`).

Terms used in this plan, in plain language:

- **STM / `atomically`**: software transactional memory. `atomically :: STM a -> IO a` runs a
  block of `TVar`/`TBQueue` operations as one atomic transaction. Calling `atomically` from a
  thread that is already inside an `atomically` block is illegal and the runtime throws
  "atomically was nested".
- **`retry` / `orElse`**: STM combinators. `retry` blocks the transaction until a read `TVar`
  changes, then re-runs it. `orElse a b` tries `a`; if `a` calls `retry`, it runs `b` instead.
- **inbox / mailbox**: NQE's bounded queue (`TBQueue`) used between ingester and processor for
  backpressure. When full, `send` blocks; when empty, the receive `retry`s.
- **ingester / processor**: two concurrent activities. The ingester (run on a `withAsync`-
  forked thread) pushes adapter messages into the inbox; the processor (run on the caller's
  thread) pulls from the inbox and runs the handler.
- **streamly**: the streaming library. `Stream.mapM`/`Stream.fold`/`StreamP.parMapM` drive the
  processor loop. `StreamP` is `Streamly.Data.Stream.Prelude` (concurrent); `Stream` is
  `Streamly.Data.Stream` (serial).

The benchmark that reproduces the crash is `shibuya-core-bench`
(`shibuya-core-bench/bench/Bench/Framework.hs`, leaf
`All.framework-overhead.processing.runWithMetrics-100`). It runs
`runShibuyaWithMessages` — 100 messages, inbox size 100, a no-op counting handler under
`runTracingNoop` (tracing disabled) — via `runWithMetrics`.


## Plan of Work

The work proceeds as five milestones. M0–M2 make the bug reproducible and understood; M3
fixes it; M4 hardens the library; M5 confirms via the full benchmark suite. Do not skip M1/M2:
per the Decision Log, the fix must be grounded in the confirmed mechanism.

### Milestone M0 — Permanent regression test that fails today

Scope: add a test to `shibuya-core-test` that drives the concurrent path enough times, on a
forked/threaded context resembling the harness, to reproduce the nested `atomically` on the
current tree. At the end of M0 a `cabal test shibuya-core-test` (or a focused test) fails with
the nested-`atomically` message on `e22462a`, giving us a red test to turn green.

Approach: call `runWithMetrics` (Unordered Serial, 100 messages, no-op handler, inbox 100) a
few thousand times, each invocation wrapped in `System.Timeout.timeout` and run via
`Control.Concurrent.Async.async` (mirroring `tasty`'s harness from S3/S5, which is what makes
it reproduce). Assert that no invocation throws. If a few thousand iterations prove flaky to
reproduce in the test runner, increase the count and/or add light concurrency; record the
count that reliably reproduces in Progress. Mark the test pending/expected-fail only until M3,
then flip it to a hard assertion.

Acceptance: the new test fails on `e22462a` with `atomically was nested`; capture the transcript
in Concrete Steps.

### Milestone M1 — Minimal reproducer that identifies the outer transaction

Scope: a standalone executable (revive `shibuya-core-bench/bench/Test/StandaloneTest.hs`, which
already exists as a debug harness) that reproduces the crash **without** `tasty` and **without**
streamly, and instruments every candidate `atomically` (shibuya's receive/metrics/ingester, and
— by temporarily vendoring thin wrappers or by adding trace points — the `unliftio`/`async`
coordination) to positively name the outer transaction. Also test `runSupervised` (Serial,
Ahead, Async) directly to answer Open Question 2 (is production affected beyond `runWithMetrics`?).

The detector used during investigation (reconstructable): a module
`Shibuya.Internal.Debug.NestGuard` exporting `guardedAtomically :: HasCallStack => STM a -> IO a`
that (a) records, in a global `IORef (Map ThreadId CallStack)` keyed by `fromThreadId`, whether
a guarded transaction is active on the current thread and reports "map" nesting if so; and
(b) wraps `atomically` in a `catch` that, on the runtime "nested" error, prints the current
`HasCallStack` site and the active-transaction map. Substitute it for `atomically` at the
receive (`inboxToStream`), metrics (`beginProcessing`/`finishProcessing`/
`recordBatchOutcomeMetrics`), and ingester (`send` → `guardedAtomically . sendSTM`) sites.

At the end of M1 we can state, with evidence, exactly which `atomically` is open when the
receive nests, and whether `runSupervised` is affected. Update Surprises S3/S5 and the Open
Questions accordingly.

Acceptance: a written, evidence-backed identification of the outer transaction in this plan.

### Milestone M2 — Document the confirmed streamly/STM interaction

Scope: with M1's evidence, write the precise mechanism in Surprises: why the concurrent
blocking receive nests, and specifically what streamly does that amplifies it ~20× (S5). If the
mechanism is a lazily-forced thunk evaluated inside the receive transaction, name the thunk. If
it is `async`/`unliftio` coordination, name the call. This milestone produces understanding,
not code, and gates the fix design in M3.

### Milestone M3 — Apply the fix

Scope: change the concurrent receive so it can never run inside another transaction, guided by
M2. The leading candidate (subject to M2's findings): **decouple the blocking inbox receive
from the stream driver.** Instead of `inboxToStream` performing `atomically (receiveSTM orElse
retry)` inside a streamly `unfoldrM` step that the concurrent/serial fold pulls, pull from the
inbox in a plain, self-contained IO step whose transaction is opened and committed in isolation
(no thunk from the transaction escaping into the stream, no streamly step re-entering while the
transaction is considered open). Concretely this may mean: (a) reading into a small owned
buffer via a dedicated IO loop and feeding streamly from that buffer; or (b) restructuring the
receive to avoid `orElse`/`retry` inside the streamed step (e.g., a two-phase check-then-block
using a separate `TVar` signal read outside the streamed transaction). The exact shape is
decided in M2/M3 and recorded in the Decision Log.

At the end of M3 the M0 test passes and the M1 reproducer prints no nesting across a high
iteration count. Keep the change minimal and preserve existing semantics: the metrics test
suite (exact `received`/`processed`/`failed` totals, in-flight visibility, final states) must
still pass unchanged.

Acceptance: M0 test green; reproducer green; `cabal test shibuya-core-test` green.

### Milestone M4 — Library-robustness hardening

Scope: make it impossible for a future refactor to silently reintroduce a nested transaction.
Options (choose in the Decision Log): (a) a small internal `atomicallyChecked` used on the hot
receive/metrics paths that, in test/debug builds, asserts the thread is not already in a
transaction and fails loudly (never silently); (b) a property/stress test in
`shibuya-core-test` that runs `runSupervised` under Serial, Ahead, and Async with a threaded,
timed harness for thousands of iterations and asserts no crash; (c) a short "Concurrency
invariants" note in `docs/architecture/` describing the rule "never open a transaction from
inside a streamed step" so the constraint is documented, not folklore. At minimum deliver (b).

Acceptance: the stress test exists, runs in CI-appropriate time, and fails if the fix is
reverted.

### Milestone M5 — Re-benchmark and record the async allocation regression

Scope: re-run the full `shibuya-core-bench` suite on the fixed tree vs `v0.7.1.0` (same method
as the investigation) to confirm the crash is gone and steady-state performance is unchanged.
Record the `Async n` allocation regression (S6) as an explicit follow-up decision: either
revert/adjust `StreamP.maxThreads n`, or accept it with documentation. Do not silently leave it.

Acceptance: benchmark suite completes with no `atomically was nested`; a decision on S6 recorded.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` unless stated otherwise.

### Reproduce the crash on the current tree (baseline for M0)

Build the benchmark and run the single failing leaf with a tight standard deviation so it
crashes on the first measured invocation:

```bash
cabal build --enable-benchmarks shibuya-core-bench
BIN=$(find dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
"$BIN" -p '$0=="All.framework-overhead.processing.runWithMetrics-100"' --stdev 1 --timeout 40 +RTS -N
```

Expected on `e22462a` (crash; it is a race, so run a few times if the first is clean):

```text
      runWithMetrics-100: FAIL
        Exception: Control.Concurrent.STM.atomically was nested
1 out of 1 tests failed (0.00s)
```

### Regenerate the before/after benchmark comparison (method used in the investigation)

```bash
# Baseline in a detached worktree at the last pre-refactor release:
git worktree add --detach /tmp/wt-0710 v0.7.1.0
( cd /tmp/wt-0710 && cabal build --enable-benchmarks shibuya-core-bench )
OLD=$(find /tmp/wt-0710/dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
# Run quiescent (nothing else on the CPU); io-bound leaves time out and are excluded:
"$OLD" --csv /tmp/old.csv --stdev 10 --timeout 45
NEW=$(find dist-newstyle -type f -path '*b/shibuya-core-bench*' -name shibuya-core-bench)
"$NEW" --baseline /tmp/old.csv --stdev 10 --timeout 45 -p '!/io-bound/'
git worktree remove --force /tmp/wt-0710
```

Interpretation notes recorded during investigation: pure-`baseline-streamly` and
`adapter-creation` leaves are byte-identical in allocation (±0.0%), confirming the method is
sound and that small-batch *timing* swings (±10–20%) are measurement noise; rely on the
deterministic **Allocated** column for regression judgements.

### Reconstruct the nesting detector (M1)

Create `shibuya-core/src/Shibuya/Internal/Debug/NestGuard.hs` exporting
`guardedAtomically :: HasCallStack => STM a -> IO a` as described in Milestone M1, add it to
`other-modules` in `shibuya-core/shibuya-core.cabal`, and substitute it for `atomically` at:
`inboxToStream` (the receive), `Shibuya.Core.Metrics.beginProcessing`/`finishProcessing`/
`recordBatchOutcomeMetrics`, and `Shibuya.Internal.Runner.Ingester.runIngesterWithMetrics`
(`send msg mailbox` → `guardedAtomically (sendSTM msg mailbox)`; import `sendSTM` from NQE).
Rebuild and run the leaf; read the `### NESTED-ATOMICALLY` block on stderr. The prior run
produced the S3 transcript. Revert all of this before committing (it is diagnostic only).

For a profiled cost-centre stack (optional, corroborating): `cabal build --enable-profiling
--profiling-detail=late shibuya-core-bench:bench:shibuya-core-bench` then run the leaf with
`+RTS -N -xc`. Profiling libraries for the whole dependency closure are available in this nix
environment (verified: the build succeeds), so `-xc` works here.

### Streamly-amplification experiment (already run; re-runnable)

Temporarily replace the `(_, Serial) ->` branch in `processUntilDrained` with a hand-rolled
recursive loop performing the same `atomically ((Just <$> receiveSTM inbox) orElse (…retry…))`
receive and calling `processAction msg` per message (no streamly). Rebuild and run the leaf
~20 times. Observed: ~1/20 crashes (vs ~20/20 with streamly), proving streamly amplifies but is
not the root. Revert after measuring.

### Run the test suite

```bash
cabal test shibuya-core-test
```

The M0/M4 tests live here (module path mirrors source under
`shibuya-core/test/Shibuya/`). Add exact expected transcripts as they are written.


## Validation and Acceptance

The change is validated by behavior, not compilation:

1. **Crash reproduced then eliminated.** On `e22462a`, the reproduce command above prints
   `FAIL … atomically was nested`. After M3, the same command prints:

   ```text
   runWithMetrics-100:   OK
     … μs ± … , … allocated
   ```

   and the M1 standalone reproducer completes its full iteration count with no nesting.

2. **Regression test.** `cabal test shibuya-core-test` includes the M0/M4 test that drives the
   concurrent Serial/Ahead/Async path thousands of times under a threaded, timed harness. It
   fails (nested `atomically`) on today's tree and passes after M3. Reverting the M3 fix must
   make it fail again (verify this explicitly and note it in Outcomes).

3. **Semantics preserved.** The existing metrics assertions in `shibuya-core-test` (exact
   `received`/`processed`/`failed` counts, in-flight visibility mid-run, `Idle`/`Failed` final
   states, batch conservation) still pass unchanged.

4. **No performance regression from the fix.** The M5 benchmark comparison vs `v0.7.1.0` shows
   no `atomically was nested` and steady-state (1k/10k message) timing/allocation within noise
   of pre-fix `master`. The pre-existing `Async n` allocation regression (S6) is recorded with
   a decision, separate from the crash fix.


## Idempotence and Recovery

All investigation and fix steps are safe to repeat. The benchmark and detector builds go to
`dist-newstyle` and do not alter source unless you edit it. The diagnostic scaffolding (NestGuard
module, `atomically` substitutions, hand-rolled Serial loop, standalone reproducer, `async`
bench dependency) must be **reverted before committing** — recover a clean tree with:

```bash
git checkout -- shibuya-core/ shibuya-core-bench/
rm -f shibuya-core/src/Shibuya/Internal/Debug/NestGuard.hs
git status --porcelain   # expect empty
```

The `git worktree` used for the baseline is disposable; remove it with
`git worktree remove --force /tmp/wt-0710`. The reproduction is a race: a single clean run does
**not** prove the bug absent — always run the leaf/reproducer many times (the M1 reproducer and
M4 stress test encode a high iteration count precisely to avoid false "green").

Every commit for this plan must carry the trailer:

```text
ExecPlan: docs/plans/29-fix-nested-atomically-race-in-concurrent-ingester-processor-path.md
```


## Interfaces and Dependencies

- `Control.Concurrent.STM` (`atomically`, `orElse`, `retry`, `readTVar`, `writeTVar`,
  `TBQueue` ops) — the STM layer where the nesting occurs.
- `Control.Concurrent.NQE.Process` (NQE `Inbox`, `receiveSTM`, `sendSTM`, `mailboxEmptySTM`,
  `newBoundedInbox`) — bounded inbox built on `TBQueue`; all plain STM.
- `Streamly.Data.Stream` (`Stream`, `mapM`, `fold`) and `Streamly.Data.Stream.Prelude`
  (`StreamP`, `parMapM`, `maxThreads`, `maxBuffer`, `ordered`) — the stream driver; implicated
  as the amplifier (S5) and the `Async` allocation regression (S6).
- `Effectful` (`withEffToIO`, `ConcUnlift Persistent Unlimited`, `runInIO`) — the effect unlift;
  MVar-based, ruled out as the STM source but present in the S3 stack.
- `UnliftIO` (`withAsync`, `waitCatch`) and transitively `Control.Concurrent.Async` — spawns the
  ingester; a candidate outer-transaction source (Open Question 1) to confirm in M1.
- Diagnostic-only (must not remain in committed code): `GHC.Conc.Sync.fromThreadId`,
  `GHC.Stack.HasCallStack`/`prettyCallStack`, a `Shibuya.Internal.Debug.NestGuard` module.

At the end of M3, the public signatures of `runSupervised`, `runWithMetrics`,
`runIngesterAndProcessor`, `inboxToStream`, and `processUntilDrained` should be **unchanged**
(the fix is internal to how the receive is performed). If any signature must change, record it
here and in the Decision Log with rationale.
