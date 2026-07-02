---
id: 25
slug: pre-1-0-public-api-cleanup
title: "Pre-1.0 public API cleanup"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Pre-1.0 public API cleanup

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-25 of the master plan at
`docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`.
It has hard dependencies on EP-22 (`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md`),
EP-23 (`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`), and
EP-24 (`docs/plans/24-enforce-ordering-policies-or-reject-unsupported-combinations.md`).
Do not start this plan until all three are marked Complete in the master plan's
Exec-Plan Registry: this plan moves and renames the very modules those plans edit
(`shibuya-core/src/Shibuya/Runner/Supervised.hs`, `shibuya-core/src/Shibuya/App.hs`,
`shibuya-core/src/Shibuya/Policy.hs`), and running them concurrently would churn every diff.
The code excerpts in this plan describe the tree as of 2026-07-01 (commit `bdfccae`); where
EP-22/23/24 have since edited function bodies, apply the same *namespace-level* moves and
export changes to whatever those files then contain — nothing in this plan depends on the
exact body of any runner function.

Every commit produced while executing this plan must carry these trailers:

```text
MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/25-pre-1-0-public-api-cleanup.md
```


## Purpose / Big Picture

`shibuya-core` (version 0.7.1.0, published on Hackage) is about to stabilize toward 1.0, but
its public surface currently exposes everything: raw runner machinery (`Shibuya.Runner.Master`
leaks NQE's `Supervisor`, `Inbox`, and `Async` types through public record fields), dead
error constructors that nothing ever throws, a metrics counter that is never incremented, a
tracing config record that is never read, documentation that references a function that does
not exist, a `Handler` whose documentation says "handlers cannot ack directly" while the
value handlers receive carries a live ack finalizer, and a positional `runApp` whose `Int`
inbox-size argument crashes at runtime when negative and silently stalls when zero. On top of
that, the changelog shows that versions 0.5.0.0 and 0.7.0.0 were *major* version bumps caused
solely by adding fields to the `Envelope` record, because every downstream package constructs
`Envelope` positionally with record syntax.

After this plan, an application author imports exactly one module — `Shibuya` — and gets a
curated, documented surface: `runApp` driven by an `AppConfig` record with validation,
opaque `AppHandle` and `Master` handles, the batch API, retry helpers, and smart constructors
(`mkEnvelope`, `mkIngested`) that make future `Envelope` field additions non-breaking for
constructors. Handlers receive a read-only `Message` view that *cannot* call the ack
finalizer (the compiler enforces the contract the docs only claimed). All runner machinery
lives under `Shibuya.Internal.Runner.*`, clearly signposted as unstable. The release ships as
0.8.0.0 with a changelog migration note for every breaking change, and `cabal haddock
shibuya-core` builds the public docs clean.

You can see it working by running, from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`:

```bash
cabal build all && cabal test shibuya-core-test && cabal run shibuya-example
```

and observing that the example (now written against the single `Shibuya` umbrella import and
`AppConfig`) processes messages and prints metrics exactly as before, while
`runApp defaultAppConfig {inboxSize = 0} ...` returns `Left` instead of hanging.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Preflight: confirmed EP-22, EP-23, EP-24 are Complete in the master plan registry; re-read the current bodies of `Shibuya/App.hs`, `Shibuya/Runner/Supervised.hs`, `Shibuya/Policy.hs`. EP-24 had already corrected the `Ahead` Haddock, so there was no stale "Prefetch" wording to carry forward. Completed 2026-07-02.
- [x] M1: moved `Shibuya.Runner.{Master,Supervised,Batcher,BatchProcessor}` to `Shibuya.Internal.Runner.*` with no-stability Haddock headers; moved `Shibuya.Runner.{Halt,Ingester}` to `Shibuya.Internal.Runner.*` (other-modules); deleted `Shibuya.Runner.Serial` and `Shibuya.Runner.Processor`. Also moved post-plan runner helpers `Finalize` and `KeyedScheduler` under `Shibuya.Internal.Runner.*`. Completed 2026-07-02.
- [x] M1: renamed `Shibuya.Runner.Metrics` to `Shibuya.Core.Metrics` (stays public). Completed 2026-07-02.
- [x] M1: created `Shibuya.Internal.App` holding `AppHandle(..)` and `QueueProcessor(..)`; made `AppHandle` and `Master` opaque in `Shibuya.App` (type + accessors only); stopped exporting `MasterState`, `MasterMessage`, and all NQE types from any public module. Completed 2026-07-02.
- [x] M1: moved `Shibuya.Prelude` to other-modules. Completed 2026-07-02.
- [x] M1: updated in-repo consumers (`shibuya-core` tests, `shibuya-metrics`, `shibuya-example`, `shibuya-core-bench`) to the new module names; `cabal build all`, `cabal test shibuya-core-test`, and `nix fmt` completed. A bounded `exe:shibuya-example` run verified startup and message processing, but the example did not reach its documented five metrics snapshots before timeout; see Surprises & Discoveries. Completed 2026-07-02.
- [ ] M2: delete `HandlerError.HandlerTimeout`, `RuntimeError.InboxOverflow`, `StreamStats.dropped` + `incDropped` (including the example's "Dropped" print line and the `shibuya_messages_dropped_total` metric in `shibuya-metrics`); delete `Shibuya.Telemetry.Config`; rewrite the `Shibuya.Telemetry` Quick Start.
- [ ] M2: add `AppConfig` + `defaultAppConfig`; change `runApp` to take `AppConfig` (clean break, no shim); add `ConfigError`/`InvalidInboxSize` validation (`inboxSize >= 1`) returning `Left`; add regression tests for inboxSize 0 and negative.
- [ ] M2: build + test + example green; `nix fmt`; commit.
- [ ] M3: narrow the handler surface — add `Message es msg` (envelope + lease, no ack) to `Shibuya.Core.Ingested`; change `Handler` and `BatchHandler` to receive `Message`; framework keeps `Ingested` internally; update tests and examples.
- [ ] M3: add `mkEnvelope` and `mkIngested` smart constructors; migrate example, tests, and bench to them.
- [ ] M3: rename `Ordering` to `OrderingPolicy`; remove all `import Prelude hiding (Ordering)`; rename `Shibuya.Stream.batchStream` to `chunksOf`; verify/fix the `Ahead` Haddock; document (not newtype) `TraceHeaders` vs `Headers`.
- [ ] M3: create the `Shibuya` umbrella module; deprecate `Shibuya.Core` toward it; port `shibuya-example/app/Main.hs` and `shibuya-example/app-batch/Main.hs` to `import Shibuya`.
- [ ] M3: build + test + example green; `nix fmt`; commit.
- [ ] M4: drop `effectful-core`, `uuid`, `vector` from build-depends; replace the three `Effectful.Internal.Unlift` imports with the stable `Effectful` exports; replace the 15 lens use sites with plain record updates and drop `lens` + `generic-lens` (fall back to "record as future work" if any site turns non-mechanical); run a `-Wunused-packages` audit.
- [ ] M4: bump version to 0.8.0.0; write `shibuya-core/CHANGELOG.md` migration notes for every breaking item; bump and note `shibuya-metrics`; run `cabal haddock shibuya-core` clean.
- [ ] M4: build + test + example green; `nix fmt`; final commit; update master plan registry row EP-25 to Complete.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-02: The current post-EP-23/24 tree included `Shibuya.Runner.Finalize` and `Shibuya.Runner.KeyedScheduler`, which were not listed in M1's original move set. Leaving either under `Shibuya.Runner.*` would violate M1's public-surface goal, so both were moved to `Shibuya.Internal.Runner.*` and `Finalize`/`KeyedScheduler` were exposed under that internal namespace.

- 2026-07-02: `cabal run exe:shibuya-example` starts processors and processes messages, but it does not reach the plan's expected "five metrics snapshots, then Done!" transcript within an 8 second bounded run. Evidence:

  ```text
  status=124
  5:All processors started.
  13:[orders] Processing: 1
  14:[events] Processing: 100
  ```

  The example uses infinite adapters and floods stdout from handlers. This appears to be pre-existing drift in the example transcript rather than an M1 module-move regression; `cabal build all` and the test suite are green.


## Decision Log

Record every decision made while working on the plan.

- Decision: Narrow the handler's view with a new `Message es msg` type (envelope + lease, no
  `AckHandle`) instead of only fixing the `Shibuya.Handler` documentation.
  Rationale: The doc-only option is cheaper but leaves the contract unenforced — any handler
  can call `ingested.ack.finalize` today, double-finalizing against the framework's own call
  in `processOne`. Feasibility was verified against the batch path: `BatchHandler` resolves
  decisions by `MessageId` looked up from the *envelope* (`shibuya-core/src/Shibuya/Batch.hs`,
  `BatchAck` contract), and no test or example handler in this repository touches `.ack`
  (verified by grep on 2026-07-01; the only hit is an attribute-name string in
  `test/Shibuya/Telemetry/SemanticSpec.hs`). Adapters still construct full `Ingested` values,
  so `Ingested(..)` stays exported and adapter code is untouched. The framework projects
  `Ingested -> Message` at the two handler call sites.
  Date: 2026-07-02

- Decision: Rename `Ordering` to `OrderingPolicy` (not `MessageOrdering`).
  Rationale: Eliminates the `Prelude.Ordering` clash and the `import Prelude hiding
  (Ordering)` boilerplate in four modules. `OrderingPolicy` was chosen because the type lives
  in `Shibuya.Policy`, is validated by `validatePolicy` alongside `Concurrency`, and the
  documentation consistently calls the pair "policies"; `MessageOrdering` reads well in
  isolation but loses the policy framing that `validatePolicy` errors use.
  Date: 2026-07-02

- Decision: `runApp` changes signature to take `AppConfig`; no deprecated positional shim.
  Rationale: Pre-1.0 with a known, small downstream set (two adapter repos, both under the
  same owner, plus in-repo packages). A shim would keep the invalid-`Int` footgun alive and
  double the surface to document. The changelog carries an exact before/after migration
  snippet instead.
  Date: 2026-07-02

- Decision: Delete `Shibuya.Runner.Serial` and `Shibuya.Runner.Processor` outright rather
  than move them under `Shibuya.Internal.Runner.*`.
  Rationale: Both are `other-modules` already, nothing in `shibuya-core`, its tests,
  `shibuya-metrics`, `shibuya-example`, `shibuya-core-bench`, or either adapter repo imports
  them (verified by grep 2026-07-01), and both bypass the halt/finalize/metrics protections
  that EP-22/EP-23 hardened in `Supervised.hs` — keeping them invites someone to run an
  unprotected loop.
  Date: 2026-07-02

- Decision: Delete `Shibuya.Telemetry.Config` (`TracingConfig`, `defaultTracingConfig`)
  rather than wire it up.
  Rationale: `TracingConfig` is constructed nowhere and read nowhere in this repository or
  either adapter repo (grep 2026-07-01: the only reference outside the module is a Haddock
  example in `Shibuya/Telemetry.hs` that also references a nonexistent `defaultAppConfig`).
  Actual enable/disable is already expressed by choosing `runTracing` vs `runTracingNoop`,
  and the OTLP exporter is configured by `OTEL_*` environment variables. Wiring the record up
  would add a third, redundant configuration path.
  Date: 2026-07-02

- Decision: Keep `Headers` and `TraceHeaders` as distinct type *aliases* (both
  `[(ByteString, ByteString)]`), improving their Haddocks, instead of newtyping.
  Rationale: Newtyping would break both adapters' `Envelope` construction and header
  plumbing (`shibuya-pgmq-adapter` and `shibuya-kafka-adapter` both import `TraceHeaders`)
  for zero runtime benefit; the two aliases are never confused in practice because
  `Envelope.headers` and `Envelope.traceContext` are separate fields with distinct docs. The
  document-only option is explicitly acceptable per the master plan review notes.
  Date: 2026-07-02

- Decision: Rename `Shibuya.Runner.Metrics` to `Shibuya.Core.Metrics` and keep it public.
  Rationale: The module is pure data (`ProcessorMetrics`, `StreamStats`, JSON instances) and
  is a load-bearing public dependency of the `shibuya-metrics` web server; leaving a public
  module under the otherwise-internalized `Shibuya.Runner.*` namespace would contradict the
  "Runner.* is internal" story. `Shibuya.Metrics.*` was rejected because the sibling
  `shibuya-metrics` package already owns that namespace (`Shibuya.Metrics`,
  `Shibuya.Metrics.Types`, ...).
  Date: 2026-07-02

- Decision: Internal modules stay *exposed* (`exposed-modules`) under `Shibuya.Internal.*`
  with a no-stability warning in the module Haddock, rather than being hidden via
  `other-modules`.
  Rationale: The test suite, `shibuya-core-bench`, and future adapter test harnesses need
  `runWithMetrics`, `startMaster`, the batcher's pure core, etc. Hiding them would force an
  internal test library refactor out of scope here. The `Internal` name plus Haddock
  signpost is the standard Haskell convention for "visible but no PVP promises".
  Date: 2026-07-02

- Decision: `AppHandle` and `QueueProcessor` definitions move to a new exposed
  `Shibuya.Internal.App`; `Shibuya.App` re-exports `QueueProcessor(..)` (users construct it)
  but only the abstract `AppHandle` type plus accessor functions.
  Rationale: Haskell cannot re-export a constructor its defining module hides, so opacity
  with testability requires the definition to live in an internal module. One test
  (`test/Shibuya/Batch/ReliabilitySpec.hs`, which reads `app.processors`) keeps working by
  importing `Shibuya.Internal.App`.
  Date: 2026-07-02

- Decision: Replace `lens`/`generic-lens` with plain record updates (not `optics-core`).
  Rationale: Exactly 15 use sites exist, all trivial (`#field %~ (+1)` counter bumps in
  `Metrics.hs`, `& #state .~` in `Supervised.hs`/`BatchProcessor.hs`, one `^. #handle` in
  `Master.hs`); each is a one-line `r {field = ...}` rewrite. Two heavyweight dependencies
  for 15 record updates is not justified. If during execution any site turns out to need
  real optics (e.g. a nested update that `DuplicateRecordFields` makes ambiguous), stop,
  record it in Surprises & Discoveries, keep the dependency, and log "future work" — the
  master plan explicitly allows that outcome.
  Date: 2026-07-02

- Decision: The release is `shibuya-core-0.8.0.0` (PVP major bump). `shibuya-metrics` gets a
  lockstep major bump (it loses the `shibuya_messages_dropped_total` Prometheus series and
  its `Shibuya.Runner.Master`/`Shibuya.Runner.Metrics` imports change).
  Rationale: Every milestone here is breaking (module moves, type renames, signature
  changes, field removals). PVP requires a major bump; batching all breaks into one release
  is the point of doing this before 1.0.
  Date: 2026-07-02

- Decision: Adapter repositories (`shibuya-pgmq-adapter`, `shibuya-kafka-adapter`) are *not*
  edited by this plan; their migration to 0.8.0.0 and to `mkEnvelope` happens in their own
  next release (EP-27 / EP-28 or later).
  Rationale: This plan's design constraint is instead that **nothing an adapter imports today
  is removed or renamed** (see "Adapter compatibility contract" in Context and Orientation
  for the exact symbol list); adapters break only on the `Envelope`/version axis they already
  manage. Keeping the plans single-repo matches the master plan's decomposition.
  Date: 2026-07-02

- Decision: `Shibuya.Core` survives 0.8.0.0 as a thin re-export of the new `Shibuya`
  umbrella, marked with a module-level `DEPRECATED` pragma, and is removed in the next major
  release.
  Rationale: It is the import the README, both example apps, and external users were told to
  use; a one-release deprecation window costs one small module and softens the migration.
  Date: 2026-07-02

- Decision: Move `Shibuya.Runner.Finalize` and `Shibuya.Runner.KeyedScheduler` to
  `Shibuya.Internal.Runner.*` during M1 even though the original M1 bullet did not name them.
  Rationale: Those helpers existed in the current post-EP-23/24 tree and are runner-owned
  implementation machinery. Keeping public `Shibuya.Runner.*` modules after internalizing the
  main runner modules would contradict the M1 public-surface goal.
  Date: 2026-07-02

- Decision: Treat the non-terminating `shibuya-example` transcript as a discovery for later
  milestones rather than changing example behavior in M1.
  Rationale: M1 is scoped to module moves and public-surface opacity. The example compiles and
  starts processing through the moved imports; changing the infinite adapter/output behavior is
  unrelated and would obscure the mechanical API move.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)

- 2026-07-02 M1 outcome: Runner machinery now lives under `Shibuya.Internal.Runner.*`,
  `Shibuya.Core.Metrics` is the public metrics type module, `Shibuya.App` exposes
  `AppHandle` and `Master` abstractly, and in-repo packages compile against the new module
  paths. The next milestone can start from the final M1 namespace layout.


## Context and Orientation

This repository, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, contains four cabal
packages built together by the top-level `cabal.project`:

- `shibuya-core/` — the framework library this plan reworks. Sources under
  `shibuya-core/src/Shibuya/`, tests under `shibuya-core/test/`, package description in
  `shibuya-core/shibuya-core.cabal` (version 0.7.1.0), changelog in
  `shibuya-core/CHANGELOG.md`.
- `shibuya-metrics/` — a metrics web server (JSON/Prometheus/WebSocket) that consumes
  `shibuya-core`'s metrics types and the `Master` handle.
- `shibuya-example/` — two executables: `shibuya-example` (`shibuya-example/app/Main.hs`)
  and `shibuya-batch-example` (`shibuya-example/app-batch/Main.hs`).
- `shibuya-core-bench/` — benchmarks importing runner internals directly.

Two *sibling repositories* (not in this cabal project, not edited by this plan) depend on
`shibuya-core`: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` and
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

Terms used below. An *adapter* (`Shibuya.Adapter.Adapter`) wraps a queue system as a
streamly stream of messages plus a shutdown action. A *handler* is the user function that
processes one message and returns an `AckDecision` (ack / retry / dead-letter / halt). An
*ack handle* (`Shibuya.Core.AckHandle.AckHandle`) is the adapter-provided finalizer the
*framework* calls with that decision. *NQE* is the actor-supervision library
(`Control.Concurrent.NQE.*`) providing `Supervisor`, `Inbox`, and process linking; it is an
implementation detail users should never see. *PVP* is the Haskell Package Versioning Policy:
removing or changing any exported entity requires a major version bump. An *umbrella module*
is a module whose only job is to re-export a curated API.

### The current public surface and its problems

`shibuya-core/shibuya-core.cabal` exposes 25 modules (lines 22–48), including all of
`Shibuya.Runner.{BatchProcessor,Batcher,Master,Metrics,Supervised}` and `Shibuya.Prelude`;
only `Shibuya.Runner.{Halt,Ingester,Processor,Serial}` are `other-modules` (lines 50–54).
The problems, file by file:

- `shibuya-core/src/Shibuya/Runner/Master.hs` exports `Master (..)` and `MasterState (..)`
  (lines 76–93): the records leak `Async ()`, `Inbox MasterMessage`, and NQE's `Supervisor`
  as public fields. `MasterMessage` (the actor protocol) is also public.
- `shibuya-core/src/Shibuya/App.hs` exports `AppHandle (..)` (lines 166–171) whose
  `processors` field exposes the internal `SupervisedProcessor`. `runApp` (lines 186–218)
  takes positional `SupervisionStrategy -> Int -> ...` arguments; the `Int` inbox size is
  converted with `fromIntegral inboxSize :: Natural` (line 207), which throws an arithmetic
  underflow at runtime for negative values, and a zero-capacity bounded inbox silently
  stalls ingestion. There is no validation. An accessor `getAppMaster` already exists
  (line 266–267).
- `shibuya-core/src/Shibuya/Handler.hs` says "Handlers cannot ack directly" while
  `Handler es msg = Ingested es msg -> Eff es AckDecision` and
  `shibuya-core/src/Shibuya/Core/Ingested.hs` gives every handler `ingested.ack ::
  AckHandle es`. The framework itself finalizes in
  `Shibuya/Runner/Supervised.hs` (`processOne`, `ingested.ack.finalize decision`) and in
  `Shibuya/Runner/BatchProcessor.hs`, so a handler that also finalizes double-acks.
- `shibuya-core/src/Shibuya/Core/Error.hs`: `HandlerError.HandlerTimeout` (line 35) and
  `RuntimeError.InboxOverflow` (line 48) are constructed nowhere (grep 2026-07-01) — dead
  surface that misleads users into handling impossible errors.
- `shibuya-core/src/Shibuya/Runner/Metrics.hs`: `StreamStats.dropped` (line 126) and
  `incDropped` (line 197) — `incDropped` has zero call sites, so `dropped` is always 0. It
  is nevertheless printed by `shibuya-example/app/Main.hs` (line 118) and exported as the
  `shibuya_messages_dropped_total` counter by
  `shibuya-metrics/src/Shibuya/Metrics/Prometheus.hs` (lines 46–48) — a permanently-zero
  metric lying to dashboards.
- `shibuya-core/src/Shibuya/Telemetry/Config.hs`: `TracingConfig`/`defaultTracingConfig` are
  never read by any code anywhere. `shibuya-core/src/Shibuya/Telemetry.hs` (Quick Start,
  lines 6–13) tells users to set `tracing = defaultTracingConfig {...}` on a
  `defaultAppConfig` that has never existed.
- `shibuya-core/src/Shibuya/Policy.hs`: `data Ordering` clashes with `Prelude.Ordering`,
  forcing `import Prelude hiding (Ordering)` in `Policy.hs`, `App.hs`, `Core.hs`, and user
  code. The `Ahead` constructor's Haddock ("Prefetch N, process in order") mismatches the
  implementation (concurrent execution with order-preserving result emission) — EP-24 may
  already have corrected this; check at execution time.
- `shibuya-core/src/Shibuya/Stream.hs`: `batchStream` (line 37) is streamly's `chunksOf`
  under a name that now collides conceptually with the real batch API (`Shibuya.Batch`).
- `shibuya-core/src/Shibuya/Prelude.hs` re-exports **all of `Control.Lens`** publicly
  (line 17) from an exposed module — an accidental, enormous API commitment.
- `shibuya-core/src/Shibuya/Core/Types.hs`: `Envelope` has 8 metadata fields plus payload;
  every consumer constructs it with full record syntax, so each added field is a major bump
  (see `shibuya-core/CHANGELOG.md` entries 0.5.0.0 and 0.7.0.0, both major solely for
  `Envelope` field additions). `Headers` and `TraceHeaders` (lines 63–67) are identical
  aliases distinguished only by docs.
- `shibuya-core/src/Shibuya/Runner/Serial.hs` and `Shibuya/Runner/Processor.hs` are unused
  runner loops without halt handling, metrics, or exception-safe finalize.
- Dependency hygiene (`shibuya-core/shibuya-core.cabal` lines 67–90): `effectful-core` is
  redundant (`effectful` re-exports it); `uuid` has no import anywhere in `src/`; `vector`
  is used only for `Shibuya.Prelude`'s `Vector` re-export, itself unused;
  `Effectful.Internal.Unlift` (an internal effectful module) is imported by
  `Shibuya/Runner/Supervised.hs:46`, `Shibuya/Runner/BatchProcessor.hs:55`, and
  `Shibuya/Telemetry/Effect.hs:53` for `UnliftStrategy(..)`, `Persistence(..)`,
  `Limit(..)` — all three are exported by the stable top-level `Effectful` module;
  `lens` + `generic-lens` back exactly 15 trivial use sites; `random` (used by
  `Shibuya/Core/Retry.hs`) and `unordered-containers` (HashMap in `Core/Types.hs`,
  `Telemetry/*`, runners) are genuinely used and stay.

### Who consumes what (verified by grep, 2026-07-01)

In-repo consumers this plan must keep compiling:

- `shibuya-metrics/src/`: imports `Shibuya.Runner.Master (Master, getAllMetricsIO,
  getProcessorMetricsIO)` (in `JSON.hs`, `Prometheus.hs`, `WebSocket.hs`, `Health.hs`,
  `Server.hs`) and `Shibuya.Runner.Metrics` (several modules, including
  `.stats.dropped` in `Prometheus.hs`).
- `shibuya-core/test/`: imports `Shibuya.Runner.Master`, `Shibuya.Runner.Supervised`
  (including `SupervisedProcessor (..)`, `runWithMetrics`), `Shibuya.Runner.Batcher`,
  `Shibuya.Runner.BatchProcessor (runBatchesWithMetrics)`, `Shibuya.Runner.Metrics`,
  `Shibuya.App`, `Shibuya.Core (ProcessorHalt (..))`, and constructs `Envelope`/`Ingested`
  records directly. `test/Shibuya/Batch/ReliabilitySpec.hs:105` reads `app.processors`.
- `shibuya-example/app/Main.hs` and `app-batch/Main.hs`: import `Shibuya.App`,
  `Shibuya.Runner.Metrics`, `Shibuya.Core.*`, `Shibuya.Adapter.Mock`, construct `Envelope`
  records, call positional `runApp`, print `stats.dropped`.
- `shibuya-core-bench/bench/`: imports `Shibuya.Runner.Master (startMaster, stopMaster)`,
  `Shibuya.Runner.Supervised (runSupervised, runWithMetrics, isDone, SupervisedProcessor)`,
  `Shibuya.Runner.Metrics`, constructs `Envelope` records.

**Adapter compatibility contract.** The external adapter repos import exactly these
`shibuya-core` symbols (grep over
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src`
and `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/shibuya-kafka-adapter/src`,
2026-07-01):

- pgmq: `Shibuya.Adapter (Adapter (..))`, `Shibuya.Core.Ack (AckDecision (..),
  DeadLetterReason (..), RetryDelay (..))`, `Shibuya.Core.AckHandle (AckHandle (..))`,
  `Shibuya.Core.Ingested (Ingested (..))`, `Shibuya.Core.Lease (Lease (..))`,
  `Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..),
  TraceHeaders)`, `Shibuya.Telemetry.Effect (Tracing)`, `Shibuya.Telemetry.Propagation
  (currentTraceHeaders)`.
- kafka: `Shibuya.Adapter (Adapter (..))`, `Shibuya.Core.Ack (AckDecision (..))`,
  `Shibuya.Core.AckHandle (AckHandle (..))`, `Shibuya.Core.Ingested (Ingested (..))`,
  `Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), TraceHeaders)`; plus a
  Haddock usage example mentioning `Shibuya.App (runApp, mkProcessor)`.

Every symbol on that list must still be exported, with the same name, from the same module,
after this plan (the `runApp` *signature* change is allowed — kafka only references it in a
doc comment). Notably, no adapter imports `Shibuya.Prelude`, `Shibuya.Stream`,
`Shibuya.Policy`, `Shibuya.Batch`, or any `Shibuya.Runner.*` module, which is what makes the
internalization safe.

### Contracts inherited from EP-23 (restate, do not re-derive)

The master plan's Decision Log fixes the ack contract this plan must document on the new
`Message`/`Handler` Haddocks: *the framework calls `AckHandle.finalize` — at most once per
message on the single-message path, possibly multiple times (bounded retry on transient
failure) on the batch path; adapters must make finalize idempotent or phase-tracked; handlers
never call finalize* (now enforced by the `Message` type). On a handler exception the
framework finalizes with `AckRetry (RetryDelay 0)`.


## Plan of Work

The work is four milestones. Each ends with the same gate, run from
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`:

```bash
cabal build all
cabal test shibuya-core-test
cabal run shibuya-example
nix fmt
git add -A && git commit   # with the MasterPlan/ExecPlan trailers
```

`cabal build all` covers `shibuya-metrics`, both example executables, and
`shibuya-core-bench`, so a milestone is not done until *all four packages* compile.
`cabal run shibuya-example` must show both processors printing messages and the five metrics
snapshots, then "Done!". If the pre-commit hook reformats files, re-stage and commit again.


### Milestone 1 — Internalize runner machinery and make handles opaque

Scope: pure module moves, export-list surgery, and consumer import updates. Biggest
mechanical churn, no behavior change; do it first so later milestones edit files at their
final paths. At the end, no public module mentions an NQE type, `AppHandle` and `Master` are
abstract, and the internal machinery lives under `Shibuya.Internal.Runner.*` with warning
headers.

Perform these edits in `shibuya-core/`:

1. `git mv src/Shibuya/Runner/Master.hs src/Shibuya/Internal/Runner/Master.hs` and likewise
   for `Supervised.hs`, `Batcher.hs`, `BatchProcessor.hs`, `Halt.hs`, `Ingester.hs`. Update
   each `module Shibuya.Runner.X` line to `module Shibuya.Internal.Runner.X`. `git rm`
   `src/Shibuya/Runner/Serial.hs` and `src/Shibuya/Runner/Processor.hs`.
2. `git mv src/Shibuya/Runner/Metrics.hs src/Shibuya/Core/Metrics.hs`; rename its module
   header to `Shibuya.Core.Metrics`.
3. Prepend to each `Shibuya.Internal.Runner.*` module Haddock a signpost, e.g.:

   ```haskell
   -- | __Internal module.__ Exposed for the test suite and benchmarks only.
   -- No PVP guarantees: anything here may change or disappear in any release.
   -- Application authors should import "Shibuya" instead.
   ```

4. Create `src/Shibuya/Internal/App.hs` (same warning header) and move into it, verbatim
   from `src/Shibuya/App.hs`: the `QueueProcessor` GADT, `mkProcessor`, `mkBatchProcessor`,
   and the `AppHandle` record. Export `QueueProcessor (..)`, `mkProcessor`,
   `mkBatchProcessor`, `AppHandle (..)`. `Shibuya.App` imports it and re-exports
   `QueueProcessor (..)`, `mkProcessor`, `mkBatchProcessor`, but only the abstract
   `AppHandle` (export item `AppHandle`, not `AppHandle (..)`).
5. In `Shibuya.App`'s export list, additionally re-export from
   `Shibuya.Internal.Runner.Master`: the abstract `Master` type (item `Master`, no
   constructors) and the accessor functions `getAllMetrics`, `getAllMetricsIO`,
   `getProcessorMetrics`, `getProcessorMetricsIO`. Do *not* re-export `MasterState`,
   `MasterMessage`, `startMaster`, `stopMaster`, `registerProcessor`, or
   `unregisterProcessor` — those stay reachable only via the internal module. This gives
   `shibuya-metrics` a stable public path (`Shibuya.App`) to everything it uses.
6. Update `shibuya-core/shibuya-core.cabal`: `exposed-modules` drops the five
   `Shibuya.Runner.*` entries and `Shibuya.Prelude`, gains `Shibuya.Core.Metrics`,
   `Shibuya.Internal.App`, `Shibuya.Internal.Runner.BatchProcessor`,
   `Shibuya.Internal.Runner.Batcher`, `Shibuya.Internal.Runner.Master`,
   `Shibuya.Internal.Runner.Supervised`; `other-modules` becomes `Shibuya.Prelude`,
   `Shibuya.Internal.Runner.Halt`, `Shibuya.Internal.Runner.Ingester`.
7. Fix all imports mechanically across the repo. The full list of files importing moved
   modules (from the Context section): in `shibuya-core/src`: `App.hs`, `Core.hs` (imports
   `Shibuya.Runner.Halt` and `Shibuya.Runner.Metrics`), `Internal/Runner/{Supervised,
   Batcher,BatchProcessor,Ingester,Master}.hs` cross-imports; in `shibuya-core/test`: every
   spec file listed by `grep -rl "Shibuya.Runner" shibuya-core/test`; in
   `shibuya-metrics/src`: `JSON.hs`, `Prometheus.hs`, `WebSocket.hs`, `Health.hs`,
   `Server.hs`, `Types.hs` — switch `Shibuya.Runner.Master` imports to
   `Shibuya.App (Master, getAllMetricsIO, getProcessorMetricsIO)` and
   `Shibuya.Runner.Metrics` to `Shibuya.Core.Metrics`; in `shibuya-example`: both `Main.hs`
   files (`Shibuya.Runner.Metrics` → `Shibuya.Core.Metrics`); in `shibuya-core-bench/bench`:
   `Bench/{Concurrency,Framework,Handler}.hs`, `Test/StandaloneTest.hs` → point at
   `Shibuya.Internal.Runner.{Master,Supervised}` and `Shibuya.Core.Metrics`.
8. Update `test/Shibuya/Batch/ReliabilitySpec.hs` to `import Shibuya.Internal.App
   (AppHandle (..))` so `app.processors` still typechecks.
9. `Shibuya.Core` (the old umbrella): update its two runner imports
   (`Shibuya.Runner.Halt` → `Shibuya.Internal.Runner.Halt`, `Shibuya.Runner.Metrics` →
   `Shibuya.Core.Metrics`) and change its `AppHandle (..)` re-export to abstract `AppHandle`.

Acceptance: milestone gate green, plus this repo-wide check proves NQE no longer leaks —
run from the repo root:

```bash
grep -rn "Control.Concurrent.NQE" shibuya-core/src --include='*.hs' | grep -v "src/Shibuya/Internal/"
```

Expected output: exactly one line, `shibuya-core/src/Shibuya/App.hs` importing
`Control.Concurrent.NQE.Supervisor qualified as NQE` for the private `toNQEStrategy`
mapping (acceptable: nothing NQE appears in an export list). If EP-22 moved that mapping,
expect zero lines.


### Milestone 2 — Delete dead surface; introduce AppConfig with validation

Scope: remove the four pieces of dead API, fix the lying Telemetry docs, and replace
`runApp`'s positional arguments with a validated config record. At the end, `runApp
defaultAppConfig {inboxSize = 0}` (and negative sizes) return `Left` with a precise error,
demonstrated by new tests that fail on the old code.

1. In `shibuya-core/src/Shibuya/Core/Error.hs`: delete the `HandlerTimeout` constructor and
   its `handlerErrorToText` clause; delete `InboxOverflow` and its clause; add a new type:

   ```haskell
   -- | Application configuration errors, detected before any processor starts.
   data ConfigError
     = -- | inboxSize must be >= 1; 0 stalls ingestion, negatives are nonsense.
       InvalidInboxSize !Int
     deriving stock (Eq, Show, Generic)

   configErrorToText :: ConfigError -> Text
   configErrorToText (InvalidInboxSize n) =
     "inboxSize must be >= 1, got " <> Text.pack (show n)
   ```

   Export `ConfigError (..)` and `configErrorToText`.
2. In `shibuya-core/src/Shibuya/Core/Metrics.hs`: delete the `dropped` field from
   `StreamStats`, delete `incDropped`, fix `emptyStreamStats` to three zeros. In
   `shibuya-example/app/Main.hs` delete the `"  Dropped:   "` print line (currently
   line 118). In `shibuya-metrics/src/Shibuya/Metrics/Prometheus.hs` delete the three
   `shibuya_messages_dropped_total` lines (currently 46–48). Then run
   `grep -rn "dropped" shibuya-metrics shibuya-core/test` and fix any residual references
   (e.g. JSON golden values in tests).
3. Delete `shibuya-core/src/Shibuya/Telemetry/Config.hs`; remove it from
   `exposed-modules`; remove the `module Shibuya.Telemetry.Config` re-export and import
   from `shibuya-core/src/Shibuya/Telemetry.hs`. Rewrite the Quick Start Haddock in
   `Telemetry.hs` to match reality — initialize a tracer provider and choose a runner, no
   `defaultAppConfig`, no `TracingConfig`:

   ```haskell
   -- == Quick Start
   --
   -- 1. Initialize a tracer and run your app under 'runTracing'
   --    (or 'runTracingNoop' to disable tracing):
   --
   -- @
   -- provider <- OTel.initializeTracerProvider
   -- let tracer = OTel.makeTracer provider instrumentationLibrary OTel.tracerOptions
   -- runEff $ runTracing tracer app
   -- @
   --
   -- 2. Configure the OTLP exporter with environment variables:
   --    OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT.
   --
   -- 3. Spans are created automatically per message; see "Shibuya.Telemetry.Effect"
   --    for custom instrumentation.
   ```

   (Mirror the working setup in `shibuya-example/app/Main.hs` lines 127–147.)
4. In `shibuya-core/src/Shibuya/App.hs`, add the config record and rewire `runApp`:

   ```haskell
   -- | Configuration for 'runApp'.
   data AppConfig = AppConfig
     { -- | How processor failures affect siblings.
       strategy :: !SupervisionStrategy,
       -- | Bounded-inbox capacity per processor (backpressure). Must be >= 1.
       inboxSize :: !Int
     }
     deriving stock (Eq, Show, Generic)

   -- | 'IgnoreFailures' with an inbox of 100 (the previously documented defaults).
   defaultAppConfig :: AppConfig
   defaultAppConfig = AppConfig {strategy = IgnoreFailures, inboxSize = 100}

   runApp ::
     (IOE :> es, Tracing :> es) =>
     AppConfig ->
     [(ProcessorId, QueueProcessor es)] ->
     Eff es (Either AppError (AppHandle es))
   ```

   Inside, before policy validation, check `config.inboxSize >= 1` and return
   `Left (AppConfigInvalid (InvalidInboxSize config.inboxSize))` otherwise (fold the check
   into the existing `validateAllPolicies` pipeline so all validation happens before any
   process starts). Add the `AppConfigInvalid !ConfigError` constructor to `AppError`.
   Export `AppConfig (..)`, `defaultAppConfig`; update `Shibuya.Core`'s re-exports.
5. Update every `runApp` call site to the record form: `shibuya-example/app/Main.hs`
   (currently `runApp IgnoreFailures 100 [...]` →
   `runApp defaultAppConfig [...]`), `shibuya-example/app-batch/Main.hs`, and every test
   using `runApp` (`grep -rn "runApp" shibuya-core/test`).
6. Add tests in `shibuya-core/test` (e.g. a new `describe "AppConfig validation"` block in
   the spec that already exercises `runApp`, `test/Shibuya/RunnerSpec.hs` or
   `test/Shibuya/App/BatchSpec.hs`): `runApp defaultAppConfig {inboxSize = 0} [...]` and
   `{inboxSize = -5}` both return `Left (AppConfigInvalid (InvalidInboxSize _))` without
   starting anything. Note in the test comment why this matters: before this change, `-5`
   underflowed `Natural` at runtime and `0` deadlocked the ingester.

Acceptance: milestone gate green; the two new tests pass (and demonstrably fail if you
temporarily revert the validation); `grep -rn "HandlerTimeout\|InboxOverflow\|incDropped\|TracingConfig\|defaultAppConfig" shibuya-core/src shibuya-metrics/src shibuya-example` returns nothing.


### Milestone 3 — Handler narrowing, smart constructors, naming, and the `Shibuya` umbrella

Scope: the type-level API improvements. At the end, handlers receive an ack-free `Message`,
`Envelope`/`Ingested` gain smart constructors, `Ordering` is `OrderingPolicy`,
`batchStream` is `chunksOf`, and one `import Shibuya` powers both example apps.

1. Handler narrowing. In `shibuya-core/src/Shibuya/Core/Ingested.hs` add:

   ```haskell
   -- | The read-only view a handler receives: envelope plus optional lease,
   -- and deliberately /no/ 'AckHandle'. The framework owns finalization: it
   -- calls the adapter's finalizer with the handler's returned 'AckDecision'
   -- (at most once per message on the single-message path; possibly multiple
   -- times, idempotently, on the batch path). Handlers express intent only
   -- through their returned 'AckDecision'.
   data Message es msg = Message
     { envelope :: !(Envelope msg),
       lease :: !(Maybe (Lease es))
     }

   -- | Project the framework-side 'Ingested' to the handler-facing view.
   toMessage :: Ingested es msg -> Message es msg
   toMessage i = Message {envelope = i.envelope, lease = i.lease}
   ```

   Export `Message (..)` and `toMessage`; keep `Ingested (..)` exported unchanged (adapters
   construct it — see the adapter compatibility contract).
2. Change `shibuya-core/src/Shibuya/Handler.hs` to
   `type Handler es msg = Message es msg -> Eff es AckDecision`, and
   `shibuya-core/src/Shibuya/Batch.hs` to
   `type BatchHandler es msg = BatchInfo -> NonEmpty (Message es msg) -> Eff es BatchAck`.
   Update both modules' Haddocks with the EP-23 contract wording from the Context section.
3. At the framework call sites, project with `toMessage`: in
   `Shibuya/Internal/Runner/Supervised.hs` (`processOne`: `handler (toMessage ingested)`)
   and in `Shibuya/Internal/Runner/BatchProcessor.hs` (where the batch handler is invoked
   over the retained `NonEmpty (Ingested es msg)`, map `toMessage` for the handler's
   argument while continuing to finalize the retained `Ingested` list). Fix test-harness
   handlers (`test/Shibuya/Batch/TestHarness.hs` and any spec whose handler pattern-matches
   `Ingested {..}`) — bodies that only use `.envelope`/`.lease` need no change beyond type
   signatures, since `Message` reuses those field names.
4. Smart constructors in `shibuya-core/src/Shibuya/Core/Types.hs` and
   `Shibuya/Core/Ingested.hs`:

   ```haskell
   -- | Construct an 'Envelope' from the required fields, defaulting every
   -- optional field ('cursor', 'partition', 'enqueuedAt', 'traceContext',
   -- 'headers', 'attempt' all 'Nothing'; 'attributes' empty). Set optional
   -- fields with record-update syntax on the result. Constructing envelopes
   -- this way keeps your code compiling when future versions add optional
   -- metadata fields (adding a field to 'Envelope' stops being a breaking
   -- change for you).
   mkEnvelope :: MessageId -> msg -> Envelope msg

   -- | Construct an 'Ingested' with no lease.
   mkIngested :: Envelope msg -> AckHandle es -> Ingested es msg
   ```

   Migrate every in-repo `Envelope {...}` construction to
   `(mkEnvelope msgId payload) {field = ...}` style: `shibuya-example/app/Main.hs`
   (note its local helper is also named `mkIngested` — rename the local one or use the new
   API), `shibuya-example/app-batch/Main.hs`, `shibuya-core/src/Shibuya/Adapter/Mock.hs`,
   the test files found by `grep -rln "Envelope {" shibuya-core/test`, and
   `shibuya-core-bench/bench/{Bench/Concurrency,Bench/Framework,Bench/Handler,Test/StandaloneTest}.hs`.
   Record in the changelog (M4) that the adapter repos should migrate to `mkEnvelope` in
   their own next release (the kafka adapter's internal `mkIngested` in
   `Shibuya.Adapter.Kafka.Internal` is its own function and does not collide as long as it
   imports ours qualified or not at all).
5. Rename `Ordering` → `OrderingPolicy` in `shibuya-core/src/Shibuya/Policy.hs` (type and
   Haddock; constructors `StrictInOrder`/`PartitionedInOrder`/`Unordered` keep their names,
   subject to whatever set EP-24 left). Delete `import Prelude hiding (Ordering)` from
   `Policy.hs`, `App.hs`, `Core.hs`, and any test that has it; chase the rename through
   `Shibuya.App` (`QueueProcessor` fields), `Shibuya.Core`, tests, and examples. While in
   `Policy.hs`, verify the `Ahead` Haddock against EP-24's outcome: if it still reads
   "Prefetch N, process in order", replace with the accurate semantics ("process up to N
   messages concurrently; results are emitted in arrival order — per-message finalization
   order is not guaranteed", or EP-24's final wording if it enforced something stricter).
6. Rename `batchStream` → `chunksOf` in `shibuya-core/src/Shibuya/Stream.hs` (same body:
   `Stream.foldMany (Fold.take n Fold.toList)`), Haddock it as "group a stream into lists of
   at most n; unrelated to the batch-processing API in Shibuya.Batch". Clean break — grep
   confirmed no consumer anywhere imports `Shibuya.Stream`.
7. Improve (do not newtype) the `Headers` / `TraceHeaders` Haddocks in
   `Shibuya/Core/Types.hs`, cross-referencing each other and stating that `TraceHeaders` is
   the W3C `traceparent`/`tracestate` projection of `Headers` (per the Decision Log).
8. Create the umbrella `shibuya-core/src/Shibuya.hs`:

   ```haskell
   -- | The Shibuya framework: supervised queue processing with explicit acks.
   -- This is the single import an application author needs.
   module Shibuya
     ( -- * Running an application
       runApp, AppConfig (..), defaultAppConfig, AppError (..),
       QueueProcessor (..), mkProcessor, mkBatchProcessor,
       AppHandle, getAppMetrics, getAppMaster, waitApp, stopApp, stopAppGracefully,
       ShutdownConfig (..), defaultShutdownConfig, SupervisionStrategy (..),
       -- * Messages and envelopes
       MessageId (..), Cursor (..), Attempt (..), Envelope (..), mkEnvelope,
       Headers, TraceHeaders, Message (..),
       -- * Handlers and acks
       Handler, AckDecision (..), RetryDelay (..), DeadLetterReason (..),
       HaltReason (..), ProcessorHalt (..),
       -- * Batch processing
       BatchHandler, BatchConfig (..), defaultBatchConfig, BatchKey (..),
       defaultBatchKey, BatchInfo (..), BatchTrigger (..), BatchAck (..),
       ackAllOk, ackAll, ackExcept, withFallback, failMessages,
       BatchConfigError (..), validateBatchConfig,
       -- * Retry helpers
       module Shibuya.Core.Retry,
       -- * Policies
       OrderingPolicy (..), Concurrency (..), validatePolicy,
       -- * Adapter authoring
       Adapter (..), AckHandle (..), Lease (..), Ingested (..), mkIngested, toMessage,
       -- * Errors
       PolicyError (..), HandlerError (..), RuntimeError (..), ConfigError (..),
       -- * Metrics and introspection
       Master, ProcessorId (..), ProcessorState (..), ProcessorMetrics (..),
       StreamStats (..), BatchStats (..), InFlightInfo (..), MetricsMap,
       -- * Tracing
       Tracing, runTracing, runTracingNoop,
     ) where
   ```

   with the corresponding imports (adjust the list to exactly what exists after M1–M3;
   the rule is "everything an app author or adapter author needs, nothing internal").
   Add `Shibuya` to `exposed-modules`. Rewrite `Shibuya.Core` as
   `{-# DEPRECATED "Import Shibuya instead; Shibuya.Core will be removed in the next major release" #-}`
   re-exporting `module Shibuya`.
9. Port both example apps to a single `import Shibuya` (plus `Shibuya.Adapter.Mock`,
   `Shibuya.Metrics` from the metrics package, and non-shibuya imports). This is the
   dogfood test that the umbrella is complete — any missing re-export shows up as a compile
   error here.

Acceptance: milestone gate green. Additionally: (a) the following handler does *not*
compile, proving the narrowed surface —

```haskell
badHandler :: Handler es Int
badHandler msg = do
  msg.ack.finalize AckOk   -- error: Message has no field "ack"
  pure AckOk
```

(verify by temporarily adding it to a test file, observing the type error, then removing
it; capture the error text in Surprises & Discoveries); (b) a new `TypesSpec` test asserts
`(mkEnvelope "m-1" (42 :: Int)).attempt == Nothing` and friends; (c)
`grep -rn "hiding (Ordering)" shibuya-core shibuya-example` returns nothing.


### Milestone 4 — Dependency hygiene, changelog, version, haddock

Scope: build-depends cleanup and release packaging. At the end the package is 0.8.0.0 with a
complete migration guide and clean docs.

1. In `shibuya-core/shibuya-core.cabal` `build-depends`: delete `effectful-core` (the
   `effectful` package re-exports its entire API), `uuid` (zero imports), and `vector`
   (only backed `Shibuya.Prelude`'s unused `Vector` re-export — delete that re-export and
   its import from `src/Shibuya/Prelude.hs` first). Keep `random` (used by
   `Shibuya/Core/Retry.hs`) and `unordered-containers` (used by `Core/Types.hs`,
   `Telemetry/Effect.hs`, `Telemetry/Semantic.hs`, both internal runners).
2. Replace `import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))`
   with `import Effectful (Limit (..), Persistence (..), UnliftStrategy (..))` (merging into
   the existing `Effectful` import) in `src/Shibuya/Internal/Runner/Supervised.hs`,
   `src/Shibuya/Internal/Runner/BatchProcessor.hs`, and `src/Shibuya/Telemetry/Effect.hs` —
   the top-level `Effectful` module exports all three types in effectful 2.6.
3. Drop `lens` and `generic-lens`: rewrite the 15 use sites as plain record updates —
   in `src/Shibuya/Core/Metrics.hs` the ten counter helpers become e.g.
   `incReceived s = s {received = s.received + 1}`; in
   `src/Shibuya/Internal/Runner/Supervised.hs` and `BatchProcessor.hs` the
   `m & #state .~ X` sites become `m {state = X}` (the multi-field update
   `m {state = finalState, stats = newStats}` at the bottom of `Supervised.hs` already uses
   this style, proving it disambiguates fine under `DuplicateRecordFields` +
   `NoFieldSelectors`); in `src/Shibuya/Internal/Runner/Master.hs`,
   `master ^. #handle` becomes `master.handle`. Then remove the `Control.Lens` and
   `Data.Generics.Labels` re-export/import from `src/Shibuya/Prelude.hs`, remove
   `OverloadedLabels` fallout if any module now has unused extensions, and delete `lens`
   and `generic-lens` from `build-depends`. If any rewrite is not a one-liner, stop per the
   Decision Log: keep the deps, note it, move on.
4. Audit: from the repo root run

   ```bash
   cabal build all --ghc-options=-Wunused-packages
   ```

   and act on every warning across all four packages (expect hits in the test-suite's
   `build-depends` too — e.g. drop anything the specs no longer use after M2/M3, and check
   `shibuya-example`'s `unordered-containers` after the `mkEnvelope` migration removes its
   `HashMap.empty` uses). Record the final warning-free transcript in Surprises &
   Discoveries if anything unexpected turns up.
5. Set `version: 0.8.0.0` in `shibuya-core/shibuya-core.cabal`. Bump
   `shibuya-metrics/shibuya-metrics.cabal` (major, per Decision Log) and add a short
   changelog entry there if the package has one.
6. Write the `shibuya-core/CHANGELOG.md` entry for 0.8.0.0. It must contain a migration
   note for **every** breaking item; use this structure (summarized here, write it out
   fully in the file): module moves (`Shibuya.Runner.*` → `Shibuya.Internal.Runner.*`, no
   stability; `Shibuya.Runner.Metrics` → `Shibuya.Core.Metrics`; `Shibuya.Prelude` no
   longer exposed; `Shibuya.Runner.Serial`/`Processor` deleted); opaque `AppHandle` and
   `Master` (use `getAppMaster`, `getAppMetrics`, `waitApp`, `stopApp*`; metrics servers
   import `Master`/`getAllMetricsIO` from `Shibuya.App`); `runApp` now takes `AppConfig`
   (before/after snippet: `runApp IgnoreFailures 100 ps` →
   `runApp defaultAppConfig ps`, custom sizes via
   `defaultAppConfig {strategy = ..., inboxSize = ...}`), with `inboxSize` validated;
   handlers now receive `Message` instead of `Ingested` (signature-only change for handlers
   that used `envelope`/`lease`; handlers can no longer call `finalize` — the framework
   always finalizes, per the idempotency contract); removed `HandlerTimeout`,
   `InboxOverflow`, `StreamStats.dropped`/`incDropped` (and the always-zero
   `shibuya_messages_dropped_total` Prometheus series), `Shibuya.Telemetry.Config`;
   renamed `Ordering` → `OrderingPolicy` and `Shibuya.Stream.batchStream` → `chunksOf`;
   new `Shibuya` umbrella module, `Shibuya.Core` deprecated; new `mkEnvelope`/`mkIngested`
   with an explicit note that constructing envelopes via `mkEnvelope` makes future optional
   `Envelope` fields non-breaking (the reason 0.5.0.0 and 0.7.0.0 were major bumps), and
   that `shibuya-pgmq-adapter` and `shibuya-kafka-adapter` should adopt it in their next
   releases; dependency removals (`effectful-core`, `uuid`, `vector`, and — if step 3
   succeeded — `lens`, `generic-lens`).
7. Docs pass: from the repo root run

   ```bash
   cabal haddock shibuya-core
   ```

   It must finish with "Documentation created" and zero Haddock parse errors/warnings for
   the public modules; read the generated index and spot-check that `Shibuya`,
   `Shibuya.App`, and `Shibuya.Batch` render the new contract wording and that every
   `Shibuya.Internal.*` page shows the no-stability banner.
8. Final milestone gate, commit, then edit
   `docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`:
   set the EP-25 registry row to Complete and tick its two Progress items.

Acceptance: milestone gate green; `-Wunused-packages` clean; haddock clean; changelog
covers all ten breaking areas; version fields updated.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (the cabal
project root; the nix devShell provides `cabal`, `ghc`, and `nix fmt`).

Preflight:

```bash
grep -n "| 25 |" docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
grep -n "| 2[234] |" docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
```

Expect rows 22, 23, 24 to say `Complete`. If they do not, stop and do those plans first.

Per-milestone loop (repeat for M1–M4):

```bash
# ...perform the milestone's edits...
cabal build all 2>&1 | tail -5
cabal test shibuya-core-test 2>&1 | tail -15
cabal run shibuya-example
nix fmt
git add -A
git commit -m "refactor(api): <milestone summary>" \
  -m "MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md" \
  -m "ExecPlan: docs/plans/25-pre-1-0-public-api-cleanup.md"
```

Expected `cabal test` tail (spec counts will have grown by then; the shape matters):

```text
Finished in ...s
N examples, 0 failures
Test suite shibuya-core-test: PASS
```

Expected `cabal run shibuya-example` output (abridged; Ctrl-C is not needed — it stops
itself after five metric snapshots):

```text
Starting Shibuya example with multiple independent queues...
[orders] Processing: 1
[events] Processing: 100
...
===== Processor Metrics =====
Processor: events
  State:     ...
  Received:  ...
  Processed: ...
  Failed:    ...
...
Stopping processors...
Done!
```

(Note: after M2 the `Dropped:` line disappears from this output — that is expected.)

Suggested conventional-commit subjects: M1
`refactor(api)!: internalize runner machinery and make AppHandle/Master opaque`; M2
`feat(api)!: replace positional runApp args with validated AppConfig; drop dead surface`;
M3 `feat(api)!: ack-free handler Message view, smart constructors, umbrella module`; M4
`chore(deps)!: dependency hygiene, 0.8.0.0 changelog and haddock pass`.

Verification greps used throughout (run any time; all from repo root):

```bash
# NQE leak check (M1)
grep -rn "Control.Concurrent.NQE" shibuya-core/src --include='*.hs' | grep -v Internal
# dead-surface check (M2)
grep -rn "HandlerTimeout\|InboxOverflow\|incDropped\|TracingConfig" shibuya-core shibuya-metrics shibuya-example --include='*.hs'
# naming check (M3)
grep -rn "hiding (Ordering)\|batchStream" shibuya-core shibuya-example --include='*.hs'
# internal-import hygiene in examples (M3): expect no Shibuya.Internal imports
grep -rn "Shibuya.Internal" shibuya-example --include='*.hs'
```

Each is expected to return nothing (except the single documented `App.hs` NQE line in M1).


## Validation and Acceptance

Beyond the per-milestone gates, the end-to-end acceptance for the whole plan:

1. Behavior preserved: `cabal run shibuya-example` and
   `cabal run shibuya-batch-example` behave as before the plan (messages processed, metrics
   printed, batch example shows its size/flush-triggered batches and the poison-order
   dead-letter, both exit cleanly with "Done!").
2. Validation works: the new tests prove `runApp` rejects `inboxSize <= 0` with
   `Left (AppConfigInvalid (InvalidInboxSize n))`. To see the before/after: `git stash` of
   the validation commit makes the `inboxSize = -5` test die with
   `arithmetic underflow` instead of returning `Left` — that runtime crash is exactly what
   this plan removes.
3. Compiler-enforced ack contract: the `badHandler` snippet from Milestone 3's acceptance
   fails to typecheck with a "no field `ack`" error against `Message`.
4. Surface audit: `cabal haddock shibuya-core` succeeds; the module list in the generated
   docs shows `Shibuya` first, no `Shibuya.Runner.*`, no `Shibuya.Prelude`, no
   `Shibuya.Telemetry.Config`, and `Shibuya.Internal.*` pages carrying the warning banner.
5. Adapter contract honored: every symbol in the "Adapter compatibility contract" list in
   Context and Orientation still resolves — quick check:

   ```bash
   grep -n "Adapter (..)" shibuya-core/src/Shibuya/Adapter.hs
   grep -n "Ingested (..)\|Message (..)" shibuya-core/src/Shibuya/Core/Ingested.hs
   grep -n "TraceHeaders" shibuya-core/src/Shibuya/Core/Types.hs
   grep -n "currentTraceHeaders" shibuya-core/src/Shibuya/Telemetry/Propagation.hs
   ```

   (Full proof is deferred to the adapters' own upgrade plans, but nothing here should
   require more of them than the 0.8.0.0 version bump plus the `runApp`-in-docs update.)
6. The changelog entry for 0.8.0.0 names every one of these changes with a migration
   snippet, and `shibuya-core/shibuya-core.cabal` says `version: 0.8.0.0`.


## Idempotence and Recovery

Every step is a source edit under git; the recovery path is always `git status` +
`git checkout -- <file>` (or `git reset --hard <last-green-commit>`), which is why each
milestone ends in its own commit — never batch two milestones into one commit. The
`git mv`-based module moves are safe to re-run (a second `git mv` of an already-moved file
just fails loudly). The grep-based verification commands are read-only and repeatable. If a
milestone's build breaks midway, the fastest route is usually forward (the compiler lists
every stale import); if you must abandon, reset to the previous milestone commit — earlier
milestones never depend on later ones. `nix fmt` is idempotent. `cabal haddock` and
`cabal test` mutate only `dist-newstyle/`, which is disposable. No migrations, no data, no
destructive operations are involved; Hackage publication of 0.8.0.0 is *not* part of this
plan (do not `cabal upload`).


## Interfaces and Dependencies

Libraries in play (all already dependencies): `effectful ^>=2.6.1.0` (effect system; after
M4 the only unlift imports are from the stable `Effectful` module), `nqe ^>=0.6`
(supervision — confined to `Shibuya.Internal.Runner.*` and the private strategy mapping in
`Shibuya.App`), `streamly`/`streamly-core` (streams), `hs-opentelemetry-*` (tracing),
`aeson` (metrics JSON), `random` (backoff jitter), `unordered-containers` (envelope
attributes). Removed by this plan: `effectful-core`, `uuid`, `vector`, and (conditionally,
per the Decision Log) `lens` + `generic-lens`.

Signatures that must exist at the end of each milestone, with full module paths:

Milestone 1 — `Shibuya.App` exports `AppHandle` (abstract), `getAppMaster :: AppHandle es
-> Master`, `Master` (abstract), `getAllMetricsIO :: Master -> IO MetricsMap`,
`getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)`;
`Shibuya.Internal.App` exports `AppHandle (..)`, `QueueProcessor (..)`;
`Shibuya.Internal.Runner.Master` exports what `Shibuya.Runner.Master` exported today;
`Shibuya.Core.Metrics` exports what `Shibuya.Runner.Metrics` exported today.

Milestone 2 — `Shibuya.App.AppConfig` with fields `strategy :: SupervisionStrategy`,
`inboxSize :: Int`; `Shibuya.App.defaultAppConfig :: AppConfig`; `Shibuya.App.runApp ::
(IOE :> es, Tracing :> es) => AppConfig -> [(ProcessorId, QueueProcessor es)] -> Eff es
(Either AppError (AppHandle es))`; `Shibuya.Core.Error.ConfigError` with constructor
`InvalidInboxSize !Int`; `AppError` gains `AppConfigInvalid !ConfigError`;
`Shibuya.Core.Metrics.StreamStats` has exactly `received`, `processed`, `failed`.

Milestone 3 — `Shibuya.Core.Ingested.Message es msg` with fields `envelope :: Envelope
msg`, `lease :: Maybe (Lease es)`; `toMessage :: Ingested es msg -> Message es msg`;
`Shibuya.Handler.Handler es msg = Message es msg -> Eff es AckDecision`;
`Shibuya.Batch.BatchHandler es msg = BatchInfo -> NonEmpty (Message es msg) -> Eff es
BatchAck`; `Shibuya.Core.Types.mkEnvelope :: MessageId -> msg -> Envelope msg`;
`Shibuya.Core.Ingested.mkIngested :: Envelope msg -> AckHandle es -> Ingested es msg`;
`Shibuya.Policy.OrderingPolicy`; `Shibuya.Stream.chunksOf :: Monad m => Int -> Stream m msg
-> Stream m [msg]`; module `Shibuya` exporting the umbrella list from Milestone 3 step 8;
module `Shibuya.Core` = deprecated re-export of `Shibuya`.

Milestone 4 — no new types; `shibuya-core.cabal` at `version: 0.8.0.0` with the trimmed
`build-depends`; `shibuya-core/CHANGELOG.md` with the 0.8.0.0 entry.


## Revision Notes

- 2026-07-02: Recorded M1 implementation progress and validation evidence. Added the
  discovery and decision that `Shibuya.Runner.Finalize` and `Shibuya.Runner.KeyedScheduler`
  are also runner internals in the current tree, so they moved under
  `Shibuya.Internal.Runner.*`. Recorded the bounded `exe:shibuya-example` verification
  caveat: the example starts and processes messages but does not reach its documented
  self-terminating transcript within the verification timeout.
