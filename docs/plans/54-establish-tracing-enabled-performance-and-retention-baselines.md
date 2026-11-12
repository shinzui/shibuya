---
id: 54
slug: establish-tracing-enabled-performance-and-retention-baselines
title: "Establish tracing-enabled performance and retention baselines"
kind: exec-plan
created_at: 2026-11-12T02:55:43Z
intention: "intention_01m76tvgq9epqr5p2vdekeetxe"
master_plan: "docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T02:55:43Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      verdict: "comments"
      note: "Corrected Consumer span counts and exporter liveness; runtime retention and benchmark checks remain unexecuted."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      verdict: "comments"
      note: "Follow-up: planning findings resolved; document checks pass; dependency, adapter and runtime validation remain implementation prerequisites."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      mode: "update"
      note: "Apply review corrections and record unresolved contracts without changing benchmark scope."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      mode: "update"
      note: "Resolve review contracts and sequencing; retain benchmark scope and external verification limits."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-12T23:12:57Z
      mode: "implement"
      note: "Implement tracing benchmark group, retention suite and baseline"
---

# Establish tracing-enabled performance and retention baselines

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shibuya is about to change how its per-message tracing span relates to the span that produced
the message (see the parent MasterPlan,
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md`). The requirement on
that work is that it introduces no performance regression and no space leak. Today that cannot
be checked: every benchmark in `shibuya-core-bench` runs with tracing disabled, and no test
asserts what a span keeps alive.

After this plan, a maintainer can run one benchmark group that measures message processing with
tracing disabled and enabled, with and without incoming trace headers, for single-message and
batch processors; and one test suite that fails if a finished span keeps a message payload alive
or if heap residency grows with the number of messages processed. This plan changes no library
behaviour. Its output is the "before" measurement that later plans compare against.


## Progress

- [x] M1 (2026-11-12): Benchmark group `tracing` exists in `shibuya-core-bench` and
  `cabal bench shibuya-core-bench --benchmark-options="-p tracing"` reports every cell of the
  matrix described in Plan of Work, with the enabled cells verified to record spans.
  Evidence: all 12 cells `OK`, each asserting 10,000 processed; `newBenchTracer` fails the run
  unless `isRecording` holds.
- [x] M2 (2026-11-12): Test suite `shibuya-core-trace-retention-test` exists, runs under
  `cabal test shibuya-core`, and passes on unchanged library code; a deliberately introduced
  retention bug makes it fail (demonstrated once, then reverted). Evidence: all four
  `shibuya-core` suites `PASS`; failing output recorded in Surprises & Discoveries.
- [ ] M3: Baseline numbers and the procedure to reproduce them are recorded in
  `shibuya-core-bench/README.md`, and `CLAUDE.md` names the new suite.


## Surprises & Discoveries

Review correction (2026-11-12): Check A now distinguishes processing spans from lifecycle
exports and keeps the exporter observably alive across collection. This corrects the existing
retention check; it adds no benchmark cells or calibration.

- A provider with no span processors does *not* produce recording spans. hs-opentelemetry-api
  1.0 sets `tracerProviderHasProcessor = not (V.null processors)` in `createTracerProvider` and
  creates non-recording spans when it is false. `newBenchTracer` caught this on its first run
  ("spans from the processor-less provider are not recording"). Both the benchmark tracer and
  retention Check B therefore use one processor whose callbacks discard every span. See the
  Decision Log.
- The master's live metrics registry drops a processor when it finishes, so `getAppMetrics`
  after `waitApp` returned no processors and the first run counted 0 processed. The benchmark
  reads each `SupervisedProcessor`'s own metrics (`getMetrics`) from the `AppHandle` instead.
- The first Check A run reported "0 of 8 payloads collected" because of the harness, not the
  library: the returned `map fst built` was a lazy thunk over the message list. Forcing each
  weak pointer before running fixed it. A weak pointer keyed on an `IORef` token inside the
  payload is used instead of one keyed on the `ByteString` box, which the optimiser may copy.
- Failure demonstration (2026-11-12). Injected into `processOne` a global
  `IORef` list prepended with each `ingested.envelope`, then reverted with
  `git checkout -- shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`:

  ```text
  FAIL: single-serial: finished spans do not retain payloads (8 Consumer spans (expected 8), 10 exported in total, 0 of 8 payloads collected)
  PASS: batch: finished spans do not retain payloads (1 Consumer spans (expected 1), 3 exported in total, 8 of 8 payloads collected)
  FAIL: single-serial: live bytes flat (N=20000 -> 200000, live bytes 11688032 -> 43693088 (limit 13905411))
  FAIL: single-async8: live bytes flat (N=20000 -> 200000, live bytes 46950648 -> 79000272 (limit 52694288))
  PASS: batch: live bytes flat (N=20000 -> 200000, live bytes 78900440 -> 101360 (limit 87839060))
  ```

  The batch cases pass because batches do not run through `processOne`. On unchanged code the
  readings are about 100–170 KB before and after, so the starting margin (1 MiB plus 10
  percent) was kept.



## Decision Log

- Decision: Enabled-path benchmarks use a real tracer from a provider with no span processors.
  Rationale: The cost under test is Shibuya's and the SDK's span construction, not an exporter.
  A provider without processors still creates recording spans under the default sampler and
  adds no I/O or background thread, so results are stable.
  Date: 2026-11-11

- Decision: Replace "a provider with no processors" with a provider holding one span processor
  whose callbacks do nothing, for the enabled benchmark cells and retention Check B.
  Rationale: hs-opentelemetry makes spans non-recording when a provider has no processors, so
  the plan's first choice measured nothing. The plan's fallback, the in-memory exporter, would
  keep every span from every benchmark iteration and grow the heap during measurement. A
  discarding processor keeps the SDK's full recording path and adds two no-op calls per span.
  Date: 2026-11-12

- Decision: Retention is tested in a new process-isolated test suite, not inside
  `shibuya-core-test`.
  Rationale: Weak-pointer and heap-residency assertions depend on major collections and on
  nothing else in the process holding references. The repository already isolates its garbage
  collection probes this way (`shibuya-core/test-gc/`).
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shibuya is a Haskell queue-processing framework. The library is the package `shibuya-core`.
An *adapter* (`Shibuya.Adapter.Adapter`, in `shibuya-core/src/Shibuya/Adapter.hs`) produces a
stream of `Ingested` messages; each wraps an `Envelope`
(`shibuya-core/src/Shibuya/Core/Types.hs`) holding the payload and metadata. One metadata field
is `traceContext :: Maybe TraceHeaders`, a short list of header name/value pairs carrying the
W3C `traceparent` (and optionally `tracestate`) written by whoever produced the message.

Tracing is an `effectful` effect, `Tracing`, in `shibuya-core/src/Shibuya/Telemetry/Effect.hs`.
`runTracingNoop` runs with tracing disabled; `runTracing tracer` runs with it enabled using an
OpenTelemetry `Tracer` from the `hs-opentelemetry-api` package. For every message, `processOne`
in `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` decodes `traceContext`, attaches it
as the parent context with `withExtractedContext`, and opens a span with `withSpan'`. For a
batch, `processCurrentBatchWithDetail` in
`shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs` does the same using the first
member's context.

The benchmark package is `shibuya-core-bench`. Its `benchmark shibuya-core-bench` stanza uses
`tasty-bench`, lists modules under `shibuya-core-bench/bench/Bench/`, and is assembled in
`shibuya-core-bench/bench/Main.hs`. `Bench/HotPath.hs` is the closest model: it builds 10,000
messages with `Shibuya.Adapter.Mock.listAdapter`, runs them through `runApp` under
`runTracingNoop` with a no-op handler, in `Serial` and `Async 8` concurrency, and returns the
processed count. `Bench/Framework.hs` documents a hazard with `tasty-bench`'s `env` and lazily
built message lists; read its comments before building inputs. Every existing benchmark uses
`runTracingNoop`, and none sets `traceContext`.

Garbage-collection probes live in `shibuya-core/test-gc/Main.hs` and
`shibuya-core/test-gc/Finished.hs`, each its own `test-suite` stanza in
`shibuya-core/shibuya-core.cabal` (`shibuya-core-gc-test`, `shibuya-core-gc-finished-test`),
plain `main` programs that print `PASS`/`FAIL` and exit non-zero on failure. The test suites
already depend on `hs-opentelemetry-exporter-in-memory`, which provides a span processor that
stores finished spans in memory for inspection; `shibuya-core/test/Shibuya/Telemetry/` shows how
the existing tests build a provider with it.

Two terms. A *weak pointer* (`System.Mem.Weak`) refers to a value without keeping it alive; after
a major garbage collection, dereferencing it yields `Nothing` if nothing else references the
value. *Live bytes* is the size of reachable heap after a major collection, read from
`GHC.Stats.getRTSStats` (field `gcdetails_live_bytes` of `gc`), which requires the runtime flag
`-T`.

Relevant ADRs:
[ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md)
establishes that an allocation increase is a regression even when time is within noise and
describes the CSV-baseline procedure used here.
[ADR 0001](../adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md) establishes
process-isolated garbage-collection suites.
[ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md)
describes the disabled-tracing contract (a shared no-op provider and sentinel span) that the
disabled benchmark cells measure.

One suspected existing inefficiency is deliberately left in place for this plan to measure:
`withExtractedContext` pattern-matches on its `Maybe SpanContext` argument before checking
whether tracing is enabled, so a message carrying a `traceparent` probably pays for header
decoding even when tracing is disabled. The "disabled, with headers" benchmark cell exists to
show this. Do not fix it here; the next plan
(`docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md`)
does.


## Plan of Work

### Milestone 1: the `tracing` benchmark group

Add `shibuya-core-bench/bench/Bench/Tracing.hs`, list it in the benchmark stanza's
`other-modules`, and add its `benchmarks` to `bench/Main.hs`. Add `hs-opentelemetry-api` to the
stanza's `build-depends` if absent.

The group is a matrix over 10,000 messages with a no-op handler returning `AckOk`:

- tracing: disabled (`runTracingNoop`) or enabled (`runTracing tracer`);
- headers: `traceContext = Nothing`, or `Just` a valid `traceparent` (use a fixed, well-formed
  value such as `00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01`; vary nothing per
  message so input construction stays out of the measurement);
- shape: single-message `Serial`, single-message `Async 8`, and a batching processor
  (`mkBatchProcessor`, see `shibuya-example` and `Bench` modules for construction) with a fixed
  batch size of 100.

Name cells so that later plans can filter them, for example
`tracing/single-serial/enabled-headers` and `tracing/batch100/disabled-headers`.

For the enabled cells build the tracer once per benchmark with `env`: create a provider with
`OpenTelemetry.Trace.Core.createTracerProvider [] emptyTracerProviderOptions` and a tracer with
`makeTracer`, exactly as `noopTracer` does in `Shibuya/Telemetry/Effect.hs`. Before trusting the
numbers, confirm these spans are recording: in a scratch check or a one-off assertion in the
module, open a span with this tracer and require `OpenTelemetry.Trace.Core.isRecording` to be
true. If a processor-less provider yields non-recording spans, attach the in-memory exporter's
processor instead and note the change in the Decision Log, because then the numbers include the
exporter's append.

Follow `Bench/Framework.hs`'s guidance on forcing inputs so message construction is not charged
to the benchmark, and have each cell return the processed count so a miscounted run is visible.

### Milestone 2: the retention test suite

Add a `test-suite shibuya-core-trace-retention-test` to `shibuya-core/shibuya-core.cabal` with
`hs-source-dirs: test-retention`, `main-is: Main.hs`, and
`ghc-options: -threaded -rtsopts "-with-rtsopts=-N2 -T"`, modelled on the
`shibuya-core-gc-test` stanza. It depends on `shibuya-core`, `hs-opentelemetry-api`,
`hs-opentelemetry-exporter-in-memory`, `effectful`, `streamly`, and whatever the mock adapter
needs. It is a plain program that runs each check, prints one `PASS:`/`FAIL:` line per check, and
exits non-zero if any fails.

Check A, *a finished span does not keep the payload alive*. Build a tracer whose provider uses
the in-memory exporter, so finished spans stay referenced by the exporter for the whole test.
Process a small number of messages (say 8) whose payloads are freshly allocated, distinct
`ByteString`s of about 1 MiB, each with a valid `traceContext`. Create a weak pointer to each
payload before handing the messages to the adapter, and make sure the test itself keeps no other
reference (build the message list inside a function that returns only the weak pointers and the
adapter; do not capture the list in a closure that outlives processing). After `runApp` finishes
and `waitApp` returns, call `performMajorGC` twice and require every weak pointer to be dead
while the exporter remains reachable and retains the finished spans. Filter by Consumer kind
when checking counts: eight individually processed messages yield eight Consumer spans; a
batch yields one Consumer span per processed batch, not per message. Internal ingestion and
shutdown spans are additional exports (ADR 0012). Run both single and batch cases, explicitly
finish application cleanup before collection, and read the retained exports after collection
so the exporter itself is demonstrably still live.

Check B, *heap residency is flat under sustained processing*. With tracing enabled on a
provider that has no processors (finished spans are not retained by anything), process N small
messages with headers, call `performMajorGC`, and read live bytes; then process 10 × N in the
same process and read again. Require the second reading to be within a fixed margin of the
first (start with 1 MiB of slack plus 10 percent, and tighten or loosen once with a recorded
rationale if the first runs show the natural noise). Use N = 20,000. Run for single-message
`Serial`, single-message `Async 8`, and batch.

Prove the suite can fail. Temporarily introduce a retention bug in the library, for example add
the whole `Ingested` to a span attribute thunk or stash each `Envelope` in a global `IORef`
list inside `processOne`, run the suite, capture the `FAIL` line in this plan's Surprises &
Discoveries as evidence, and revert the change before committing.

### Milestone 3: record the baseline

Run the `tracing` group on an otherwise idle machine and save the CSV. Add a section to
`shibuya-core-bench/README.md` named "Tracing benchmarks" containing the cell names, a table of
time and allocated bytes per cell from this run, the machine and GHC version, the commit hash,
and the exact commands for producing a baseline CSV from a git worktree and comparing a working
tree against it (given in Concrete Steps). State the reading rule from ADR 0006: any increase in
the `allocated` column must be explained, even when time is within noise. Note in the README
what the "disabled, with headers" cells show relative to "disabled, no headers"; that difference
is the suspected decode-when-disabled cost and is input to the next plan.

Update the Commands block in `CLAUDE.md`: the comment after `cabal test shibuya-core` currently
names three suites; add `shibuya-core-trace-retention-test`.


## Concrete Steps

All commands run from the repository root inside the nix devShell.

Build and run the new group:

```bash
cabal build shibuya-core-bench
cabal bench shibuya-core-bench --benchmark-options="-p tracing --stdev 5 --timeout 120"
```

Expected shape of the output (numbers will differ):

```text
All
  tracing
    single-serial
      disabled-noheaders: OK
        1.9 ms ± 90 μs, 7.5 MB allocated, ...
      disabled-headers:   OK
      enabled-noheaders:  OK
      enabled-headers:    OK
    single-async8
      ...
    batch100
      ...
```

Save the baseline CSV:

```bash
cabal bench shibuya-core-bench \
  --benchmark-options="-p tracing --stdev 5 --timeout 120 --csv /tmp/shibuya-tracing-baseline.csv"
```

The comparison procedure to document for later plans, where `<baseline-commit>` is the last
commit of this plan:

```bash
git worktree add /tmp/shibuya-tracing-baseline <baseline-commit>
( cd /tmp/shibuya-tracing-baseline && \
  cabal bench shibuya-core-bench \
    --benchmark-options="-p tracing --stdev 5 --timeout 120 --csv /tmp/shibuya-tracing-baseline.csv" )
cabal bench shibuya-core-bench \
  --benchmark-options="-p tracing --stdev 5 --timeout 120 --baseline /tmp/shibuya-tracing-baseline.csv --fail-if-slower 10"
git worktree remove /tmp/shibuya-tracing-baseline
```

Run the retention suite alone and as part of the package:

```bash
cabal test shibuya-core:test:shibuya-core-trace-retention-test --test-show-details=direct
cabal test shibuya-core
```

Expected:

```text
PASS: single: finished spans do not retain payloads (8 spans, 8 payloads collected)
PASS: batch: finished spans do not retain payloads
PASS: single-serial: live bytes flat (N=20000 -> 200000)
PASS: single-async8: live bytes flat
PASS: batch: live bytes flat
```

Format and check before committing:

```bash
nix fmt
cabal build all
```


## Validation and Acceptance

The plan is accepted when all of the following hold.

Running the `tracing` group prints every cell of the matrix (2 tracing modes × 2 header modes ×
3 shapes = 12 cells), each returning the expected processed count, and the enabled cells have
been confirmed to create recording spans.

The existing benchmark groups are unchanged: `cabal bench shibuya-core-bench` still lists
`hot-path`, `handler`, `concurrency`, `framework` and the others with the same cell names.

`cabal test shibuya-core` runs four suites and all pass. The retention suite has been shown to
fail under a deliberately introduced retention bug, with the failing output recorded in this
plan.

`shibuya-core-bench/README.md` contains the baseline table and the comparison procedure, and a
second person can reproduce a CSV by following it.

No file under `shibuya-core/src/` is changed by this plan; `git diff --stat` for the plan's
commits shows only `shibuya-core-bench/`, `shibuya-core/shibuya-core.cabal`,
`shibuya-core/test-retention/`, `CLAUDE.md`, and this plan.


## Idempotence and Recovery

Everything here is additive. Benchmarks and tests can be run any number of times. The
temporary retention bug in Milestone 2 must be removed by reversing only the injected edit
before committing; inspect the diff to preserve any unrelated working-tree changes. If the heap
residency check proves flaky, do not loosen it silently: record three consecutive readings in
Surprises & Discoveries, choose a margin from them, and log the decision. `git worktree remove`
cleans up the baseline tree; if a previous run left it behind, remove it and repeat.


## Interfaces and Dependencies

Uses `tasty-bench` (already a dependency of `shibuya-core-bench`), `hs-opentelemetry-api`
`^>=1.0` (`OpenTelemetry.Trace.Core`: `createTracerProvider`, `emptyTracerProviderOptions`,
`makeTracer`, `tracerOptions`, `isRecording`), `hs-opentelemetry-exporter-in-memory` `^>=1.0`,
`System.Mem` (`performMajorGC`), `System.Mem.Weak` (`mkWeakPtr`, `deRefWeak`) and `GHC.Stats`.

This plan has no prerequisites. It provides, for the two plans that follow it under the parent
MasterPlan, the benchmark cell names under `tracing/…`, the retention suite
`shibuya-core-trace-retention-test`, and a commit that those plans check out as their baseline.
Those plans add cells and checks for their new behaviour; they must not rename or remove the
cells created here.
