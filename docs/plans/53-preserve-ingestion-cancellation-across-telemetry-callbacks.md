---
id: 53
slug: preserve-ingestion-cancellation-across-telemetry-callbacks
title: "Preserve ingestion cancellation across telemetry callbacks"
kind: exec-plan
intention: "intention_01m5sydxvdepmrqsvv1kt9vj1b"
created_at: 2026-10-25T16:29:13Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-25T16:29:13Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T18:42:22Z
      mode: "implement"
      note: "Implement authorized ingestion cancellation repair; red tests reproduce onStart and onEnd cancellation loss."
---

# Preserve ingestion cancellation across telemetry callbacks


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current during implementation. Follow
`.codex/skills/exec-plan/PLANS.md` and record material implementation friction through the
skill's friction workflow.


## Purpose / Big Picture


Stopping a processor must not start its adapter source after the framework has cancelled
that source. With tracing enabled, the new ingestion lifetime span can currently swallow
cancellation inside an OpenTelemetry callback and then enter a source poll. A poll that
would normally respond to cancellation can consequently hold forced shutdown open.

After this fix, single-message and batch processors stop even when cancellation arrives
while an ingestion span is starting or ending. Normal ingestion still produces one lifetime
span with processor identity, and disabled tracing keeps its inexpensive direct path.
Regression tests will demonstrate that the source never starts after cancellation at span
creation and that the application stop operation completes.

Implementation was authorized on 2026-10-25. The separate investigation of the
100-message standalone counter slowdown is outside this plan's acceptance criteria.


## Progress


- [x] (2026-10-25) Milestone 1: Four callback-cancellation regressions fail on the original wrapper (18 lifecycle examples, 4 failures); explicit gate cleanup finishes the red run.
- [x] (2026-10-25) Milestone 2: Owned SDK worker preserves cancellation for single/batch and direct ingestion; all four initially failing callback cases pass.
- [x] (2026-10-25) Milestone 3: All 287 core examples, 104 metrics examples, and both isolated GC suites pass; formatting and diff checks pass. ADR 12 and the unreleased changelog document the ownership repair.


## Surprises & Discoveries


The SDK's onEnd catch can turn direct ingestion cancellation into successful completion,
independently of the onStart source-entry problem. Both need owner-side cancellation.
The four red cases finished with explicit gate cleanup; after the repair, the original
18 lifecycle examples passed in 0.245 seconds. Five additional examples cover enabled
thread/local-state/context preservation for both runners, running/paused cancellation,
and source-error precedence when onEnd also fails.


## Decision Log


2026-10-25: Scope the repair to ingestion lifetime tracing. Preserve the existing public
tracing API, processor ownership, and once-only adapter shutdown behavior. A generic rewrite
of per-message tracing and a dependency upgrade are separate work. The existing shutdown
span implementation provides the ownership pattern needed here.

2026-10-25: Keep source effects on the ingester's owning thread and Effectful environment;
put SDK lifecycle callbacks on an owned tracing worker only when tracing is enabled. This
prevents callbacks from consuming source cancellation without moving adapter-local state or
adding a worker, synchronization, or clock read per ingested message.

2026-10-25: Use `SeqUnlift` for ingestion rather than copying shutdown's concurrent
unlift. Only the owning thread invokes the unlift; the worker executes pure IO SDK calls.
This preserves caller-local source state without cloning or moving its environment.


## Outcomes & Retrospective


Implemented on 2026-10-25. The private ingestion wrapper owns an SDK worker only when
tracing is enabled. Source work retains its original thread and local effect environment
through `SeqUnlift`; context is attached for the fold and restored afterwards. The callback
regressions fail on the original wrapper and pass with the repair. All 287 core examples,
104 metrics examples, and both isolated GC suites pass using the commands below; `nix fmt`
and `git diff --check` pass. Full-suite evidence is in `/tmp/shibuya-ep53-full.log`.

ADR 12 records the durable cancellation boundary. No material skill/tool friction was
recorded. No dependency, public signature, benchmark workload, or release threshold changed.
This plan is complete; the separately authorized performance investigation remains open.
No performance recovery is claimed by this correctness repair.


## Context and Orientation


The repository contains the `shibuya-core` runtime and the `shibuya-metrics` observer server.
An ingester is the thread that pulls messages from an adapter's source stream and sends them
to a bounded inbox. A span is a tracing record; an SDK span processor may execute arbitrary
IO in `onStart` and `onEnd` callbacks when that record opens or closes.

`shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs` defines
`runIngesterWithMetrics`, `runIngesterWithMetricsUnpaused`, and their common
`traceIngestion`. The first runner checks pause intent before each stream step; the second
serves blocking standalone helpers that expose no live pause control. At review time, both wrapped
the complete source fold in `withSpan' ingestSpanName internalSpanArgs`; the repair replaces
that wrapper with the owned SDK worker described below.

`shibuya-core/src/Shibuya/Telemetry/Effect.hs` implements `withSpan'` using the SDK's
`inSpan'` when enabled. The selected SDK catches `SomeException`, including
`AsyncCancelled`, around span processor callbacks. A surrounding catch cannot recover an
exception that the SDK has already consumed. In particular, catching cancellation during
`onStart` lets the SDK call the source action afterwards.

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` owns ingester async handles through
`withAsync`, publishes source completion in a `finally` handler, and joins ingestion before
finishing. Its single and batch paths share the defective ingestion wrapper. During forced
stop, cancelling and joining that owned ingester can therefore remain blocked. The flag
`totalShutdownTimeout` in `shibuya-core/src/Shibuya/App.hs` bounds the graceful phase;
forced master cleanup occurs afterwards. Do not claim that this change imposes a hard bound
on arbitrary uninterruptible adapter or exporter code.

The local `traceShutdown` implementation in `shibuya-core/src/Shibuya/App.hs` already keeps
SDK callbacks on a separate owned thread. It exchanges a ready span and an outcome with the
caller, while only the caller executes adapter effects. Use its cancellation handling as a
reference, while preserving ingestion's source thread and environment.

The review reproduction at `016576f` used an in-memory exporter whose `onStart` signals an
MVar and then blocks only for `shibuya.ingest`. The caller waits for that signal before
calling `stopAppGracefully` with a 10 ms drain timeout and a 100 ms graceful-phase timeout.
The source records entry and performs an interruptible 60-second wait. Both single and
batch processors entered the source after the SDK logged `AsyncCancelled`, and neither stop
returned within a one-second observation window. With the callback block removed, the same
source was cancelled and stop returned `False`. These facts establish cancellation loss;
they do not require the temporary reproduction script to remain available.

Relevant decisions are
[ADR 12](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md),
which requires one ingestion lifetime span without changing cancellation or provider
ownership, [ADR 3](../adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md),
which requires owned cleanup and cached stop outcomes, and
[ADR 10](../adr/0010-pause-processors-at-the-adapter-source-and-report-pause-as-operator-intent.md),
which requires shutdown to clear pause intent before cancellation. ADR 10 still describes
an older zip-based admission implementation; the current runner uses `Stream.morphInner`
and its implementation is authoritative. No new ADR is needed merely to restore these
existing contracts; update ADR 12's overly broad statement that SDK brackets preserve all
cancellation when the repair is verified.


## Plan of Work


### Milestone 1: Turn the review reproduction into an owned regression test


Extend `shibuya-core/test/Shibuya/Telemetry/LifecycleSpec.hs`. Reuse its
`withExporterUsing` setup, but add an ingestion-specific callback hook; the existing
`blockingShutdownHook` deliberately matches only shutdown spans and does not cover this bug.
Start with a single processor, wait for its ingestion `onStart` barrier, then stop the app.
Assert that forced stop returns `False` and that the source-entry counter remains zero.
Repeat for the batch processor. Verify that both tests fail on the current implementation.

Use explicit release gates for the hook and source and release them during test teardown
before joining test-owned async handles. A timed-out `withAsync` can itself hang while
joining the defective ingester, so the failure path must unblock both gates. Keep gates
reachable until teardown; an unreferenced `atomically retry` can be collected and raise
`BlockedIndefinitelyOnSTM`, falsely making the cancellation test pass. Use barriers to
establish the schedule and a generous one-second observation window only to bound the test.

Add a focused direct-ingester cancellation case for the standalone/unpaused path: after
cancelling the ingester while its span starts, joining it reports an asynchronous exception
and the source has not entered. This avoids confusing the application's successful forced
stop result (`False`) with the ingester's cancellation exception.

### Milestone 2: Give source cancellation an owner outside SDK callbacks


Replace the private `traceIngestion` wrapper in
`shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs`. Check whether tracing is enabled once
per source lifetime and run the original action directly when it is disabled. For enabled
tracing, obtain the existing tracer and current context. Create an owned worker that opens
`shibuya.ingest`, sets `shibuya.processor.id`, publishes the span through a ready cell, waits
for the source outcome, and returns or throws that outcome inside the SDK span bracket.
A cell here means a transactional variable used to deliver one value between threads.

The ingester owner waits for either the ready span or early worker failure. Only this owner
may execute the source fold. Attach the published span to the owner's context for the fold
and restore the prior context afterwards. Preserve the original `Eff` action on that thread
rather than running it on the tracing worker; caller-local effects must retain their state.
Mask ownership transfers, restore interruptibility around source work and readiness/export
waits, and publish the source outcome before releasing the worker. Preserve the original
source or asynchronous exception when tracing cleanup also fails. Never start source work
in a callback, and never detach a worker to make cancellation appear to finish.

If owner cancellation arrives during span creation, publish cancellation and cancel/join
the worker. Even if `onStart` consumes that worker cancellation, the worker must observe the
published outcome instead of running the source. Cancellation during `onEnd` must likewise
remain an exception in the owner. Keep worker creation and handshakes outside both ingestion
loops. Prefer a private implementation here; extraction shared with `traceShutdown` is only
useful if its existing behavior and tests remain unchanged.

Complete callback cancellation coverage with `onEnd`, an ordinary running source, and a
paused source. For `onEnd`, use a finite source and cancel while export is blocked; verify
that cancellation is not turned into successful ingester completion. Preserve normal source
failure identity and successful completion behavior.

### Milestone 3: Verify compatibility and record the ownership contract


Run the focused telemetry and pause tests and then all core suites plus the metrics suite.
Extend the source-local-state and thread-identity assertion in
`shibuya-core/test/Shibuya/Runner/PauseSpec.hs`, or an equivalent fixture in LifecycleSpec,
to cover enabled tracing as well as disabled tracing. Check normal single/batch ingestion
span counts and attributes, parent context attachment/restoration, cancellation export when
the exporter is responsive, once-only shutdown, cached stop results, and unchanged disabled
behavior. Existing tests should supply these checks wherever possible.

Update ADR 12 and the unreleased changelog to explain which thread owns source effects and
which owns SDK callbacks. Record actual test results in this plan. This repair does not
resolve the separately documented `counter-100` performance finding and must not remove
that note or claim a complete performance pass. Use only the established benchmark workflow
if performance validation is requested; changes to profiles, workloads, calibration, or
additional diagnostic variants require the user's permission under `AGENTS.md`.


## Concrete Steps


Run these commands from the repository root. The Nix development environment supplies GHC
9.12.4; the user's default compiler may be older. Explicit `--enable-tests` avoids selecting
a build plan that excludes the test components.

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
nix develop --no-write-lock-file -c cabal test shibuya-core-test --enable-tests --test-show-details=direct --test-options='--match Shibuya.Telemetry.Lifecycle'
nix develop --no-write-lock-file -c cabal test shibuya-core-test --enable-tests --test-show-details=direct --test-options='--match "pause and resume"'
```

Before the fix, the new ingestion callback tests must fail with source entry after
cancellation or a bounded stop/join failure. After the fix, both focused commands must report
zero failures. Then run the complete affected suites:

```bash
nix develop --no-write-lock-file -c cabal test shibuya-core-test shibuya-core-gc-test shibuya-core-gc-finished-test shibuya-metrics-test --enable-tests --test-show-details=direct
nix fmt
git diff --check
```

The review baseline passed 278 core examples, 104 metrics examples, and both isolated GC
suites. New regression examples increase the count; all suites must pass. Inspect formatter
changes and retain only relevant modifications. Record evidence in temporary storage and a
concise summary here; do not commit generated build products or bulk logs.


## Validation and Acceptance


The decisive check is an interruptible ingestion `onStart` blocked behind a test barrier:
force-stop single and batch applications, observe `False`, and observe zero source entries.
The direct ingester check must instead retain its asynchronous exception. Teardown must
complete on both the red and green versions, with no unowned workers.

Cancelling during ingestion `onEnd` must not become a successful return. A normal source
must execute on its original thread with its local effect state preserved and its ingestion
span attached, then restore the earlier context. Normal lifetimes still export exactly one
`shibuya.ingest` span with processor identity for each single or batch source. Disabled
tracing exports none and does not create a tracing worker. Responsive export must preserve
existing source exception and cancellation diagnostics. The complete affected test suites
and formatting check must pass.

This is a correctness repair for interruptible callbacks. It neither promises forcible
termination of uninterruptible third-party code nor changes the stop API's timeout semantics.
No live queue service, dependency upgrade, new benchmark harness, or performance threshold
change is required for these acceptance criteria.


## Idempotence and Recovery


Tests use in-memory adapters and exporters and explicit cleanup gates; they can be rerun
without external state. Do not remove cancellation brackets or leave a background worker
running to make the regression test finish. If a test fails, release its gates and join its
owned threads before reporting failure. Changes are ordinary source and test edits; no data
migration, release, or branch creation is needed. Preserve unrelated working-tree changes.


## Interfaces and Dependencies


Keep public `runApp`, `stopApp`, `stopAppGracefully`, `Tracing`, and `withSpan'` signatures
unchanged. The private `traceIngestion` continues to accept a `ProcessorId` and an `Eff es ()`
source action with `IOE` and `Tracing` constraints. Both ingester entry points retain their
existing pause and metrics behavior. No external service is involved.

The relevant SDK is `mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-api`; Effectful
is `mori://effectful/effectful/packages/effectful-core`. Use Mori before relying on dependency
APIs, for example:

```bash
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
mori registry show effectful/effectful --full
```

Inspect the selected SDK's `createSpanHelper`, `inSpanInternal`, and `endSpan` implementations
and its span processor exception handling, plus Effectful's ownership/unlifting behavior.
The current `cabal.project` selects the `hs-opentelemetry-api-types-1.0.0.0` source tag. This
plan does not choose new bounds or pins; any proposed dependency change must first be checked
against the authoritative registry and upstream tags. This is a standalone repair plan,
with no new MasterPlan or release dependency.
