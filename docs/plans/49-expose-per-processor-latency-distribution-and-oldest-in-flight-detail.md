---
id: 49
slug: expose-per-processor-latency-distribution-and-oldest-in-flight-detail
title: "Expose per-processor latency distribution and oldest in-flight detail"
kind: exec-plan
created_at: 2026-09-30T23:27:06Z
intention: "intention_01m3ta8zgtebmaz00g0snjzy5a"
master_plan: "docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:27:06Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T19:49:01Z
      verdict: "changes-requested"
      note: "Original draft review found API/concurrency and performance-evidence defects; addressed in the accompanying update. Implementation and measured acceptance remain pending."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T19:49:01Z
      mode: "update"
      note: "Apply API and performance review: bounded concurrent state, explicit control semantics, basic default, and candidate-bound integrated regression gates."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T22:08:53Z
      mode: "implement"
      note: "Implement bounded opt-in latency and in-flight accounting with measured acceptance."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T19:32:42Z
      mode: "implement"
      note: "Implement browser inspection/control with bounded remote quick performance scope."
---


# Expose per-processor latency distribution and oldest in-flight detail

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An operator watching a Shibuya processor today sees its state, its received, processed, and
failed counters, its batch counters, and how many messages are in flight. Three questions have
no answer: how long each message takes, which message the processor has been holding the
longest, and how old that message is. After this plan, `GET /metrics/<processorId>` on the
`shibuya-metrics` server, the Prometheus text at `/metrics/prometheus`, and every WebSocket
`snapshot` and `update` frame carry a processing-latency distribution for the processor (a
count, a sum of seconds, and cumulative bucket counts suitable for a percentile panel) and,
while work is in flight, the identity, start time, and age of the oldest in-flight message. A
client written against the 0.10.0.0 surface keeps working: the additions are new optional
members and new Prometheus series, and nothing that exists today is renamed, removed, or
re-typed.

The message hot path is protected. Detailed accounting uses a bounded table with synchronized slot publication and lives behind
a `MetricsDetail` switch. `defaultMetricsDetail` is `MetricsBasic` throughout this initiative.
The basic path performs no detail clocks, slot operations, or cleanup brackets. Detailed
allocation and contention are measured costs, not assumed to be zero; changing the default
requires a later explicit decision backed by integrated measurements.
You can see the result by starting `shibuya-example`, letting a few messages through, and
fetching `http://127.0.0.1:9090/metrics/<processorId>`: the JSON gains a `latency` object
once a message has completed, and a blocked handler shows an `oldestInFlight` object whose
`ageSeconds` grows between two fetches and disappears after acknowledgement.

This plan delivers the latency and in-flight items of the improvement request
`docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md`
(IR-3). Its cursor-progress item is delivered by
`docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md`, which also
closes the request; that plan reuses the detail switch, the encoder options, the hook points,
and the fixtures this plan introduces.


## Progress


- [x] (2026-10-10 22:16Z) Milestone 1, accounting: add `MetricsDetail`, `DetailOptions`, `defaultMetricsDetail`, `LatencySummary`, `LatencyBucket`, `OldestInFlight`, the slot table, and the sharded histogram to `shibuya-core/src/Shibuya/Core/Metrics.hs`; use existing base and containers dependencies.
- [x] (2026-10-10 22:16Z) Milestone 1, hooks: add `claimInFlightSlot` and `releaseInFlightSlot`; call them from `processOne` and `processOneBatchWithDetail`; add `runSupervisedWith` and `runSupervisedBatchWith`; add `metricsDetail` to `AppConfig`.
- [x] (2026-10-10 22:16Z) Milestone 1, unit tests: `shibuya-core/test/Shibuya/Core/MetricsSpec.hs` for claim, release, bucketing, concurrent publication and cancellation cleanup, and sampling with an injected clock; suite green.
- [x] (2026-10-12) Milestone 1, measurement scope revised: retain historical inconclusive results and detailed cost diagnostics; one final remote quick comparison belongs to EP-52, with no per-child measurement gate.
- [x] (2026-10-10 22:16Z) Milestone 1, default: `defaultMetricsDetail` remains `MetricsBasic`; detailed overhead reported; decision recorded below.
- [x] (2026-10-10 22:16Z) Milestone 2, JSON: `ProcessorMetrics` encoders omit `Nothing` members; `MessageId` JSON instances; golden fixture gains a detailed processor.
- [x] (2026-10-10 22:16Z) Milestone 2, Prometheus: `shibuya_message_processing_seconds` histogram and `shibuya_processor_oldest_in_flight_seconds` gauge; golden updated deliberately.
- [x] (2026-10-10 22:16Z) Milestone 2, WebSocket: the WebSocket push producer compares an age-zeroed projection; update frame test.
- [x] (2026-10-10) Milestone 2, runner behavioral tests: blocked handler age growth and clearing, `Async 4` oldest identification, batch processor duration, RTS allocation check on the basic path remains in the paired measurement item.
- [x] (2026-10-10) Milestone 3, records: ADR, `docs/architecture/METRICS.md`, Haddock, `docs/user/getting-started.md`, CAP-9 and CAP-10 evidence with `okf log add`, three changelogs.


## Surprises & Discoveries


2026-10-10 implementation: Added 17 feature examples. The final core suite passes 250 examples under `-N1` and `-N4`; metrics passes 92 examples; both GC suites and `cabal build all` pass. Basic JSON objects and existing Prometheus series retain their bytes. Accounting, wire and age-only WebSocket mutations were observed failing; the lifetime-sum overflow mutation fails with seed 902585140. Required capability profile/log validation passes; strict validation reports inherited missing recommended reviews on ten existing records.

2026-10-10 performance correction: Candidate `b7567a2` added about 15.5% basic allocation in serial/retry/dead-letter work. Commit `67f00ec` removes retained detail closures by selecting the mode outside the loop through an OPAQUE accessor and passing literal Bool arguments into INLINE workers. NOINLINE alone permits worker/wrapper decomposition and was insufficient. The corrected candidate passes the focused basic allocation cells; overall performance acceptance remains inconclusive. No budget was relaxed.

2026-10-10 measurement diagnosis: Retrospectively pair odd/even baseline samples from the existing 200-run captures (100 pairs, unchanged budgets). The unchanged baseline is inconclusive against itself: full-inbox live memory has a 95% adverse-ratio interval of 0.9473–1.0749; retry throughput has 0.9419–1.1352. This is a diagnostic of measurement instability, not evidence that the feature passes. Baseline live-memory variation is about 25% and retry throughput variation about 37%. The full-inbox fixture previously let ingestion and processing race, so automatic GC sampled different backlog populations. Hold the first handler until the backlog is populated and force a major GC while it is retained; workload version 4 prevents mixing old and corrected samples. Compile the identical corrected harness against baseline and candidate.

The paired capture now supports `--stability-budgets`: compare fresh baseline runs against baseline runs in both directions before measuring the candidate. Use the unchanged budget and its minimum pair count; a non-pass exits 2 and skips candidate capture. Store control captures as ineligible for release comparison. Existing comparator tests pass (8); driver smoke checks prove stable controls proceed and unstable controls skip the candidate. The corrected checkpoint builds at O2 for both revisions and acknowledges every message for counts below, at and above inbox capacity. No new test cases or audit files were added to the repository.

The user reports a very busy machine; observed load was about 34 on ten cores. Smoke-run timings are ignored. Do not run or accept local wall-time measurements while the machine remains busy. There is no existing CI workflow or registered self-hosted Actions runner. A quiet host must pass the baseline stability control before the fresh, bounded paired acceptance run. Dependent work remains blocked and no budget is waived.

2026-10-10 scope correction: Stop additional tests and performance sampling at the user's request. Remove all 176 generated EP-49 audit files from the repository, including the two previously committed files. Keep this verification summary and the reproducible commands below; future diagnostic output belongs in temporary storage.

2026-10-10 review: Remove nonexistent primitive atomic APIs, publish complete slots under per-slot locks, make cleanup exception-safe, and keep detailed accounting opt-in. Zero-allocation claims require measurement, not prose.


## Decision Log

Decision (2026-10-12): Performance validation follows the user’s 2026-10-12 instruction to use the existing remote fast lane and avoid overengineering. Run one bounded exact-revision comparison for the integrated candidate through `mori://shinzui/keiro-runtime-kenshou/okf/runbooks/concepts/RB-2`, using the supplied `shibuya-core-quick` profile and the runbook’s prepare/run/verify workflow. Baseline is the clean pre-initiative commit; candidate is the final committed implementation. Keep request, exact revisions, harness identity, session/receipt and report references in EP-52. Use temporary or Kenshou-owned scratch storage for raw output, not a new Shibuya audit framework. Do not expand profiles, run calibration batches, add benchmark variants, or repeat statistically valid results to chase a pass. The current quick profiles are uncalibrated: use `purpose: calibration`, report `gatingEligible: false`, and do not call an exploratory result release certification. Report regressions, incomplete coverage and infrastructure failures plainly. Functional child acceptance no longer waits for per-child performance matrices; release certification remains separate under ADR-0002. MetricsBasic stays the default; deterministic feature tests establish detailed cursor and timing correctness. This scope supersedes the older local full-matrix and observer-load prescriptions for this implementation.


- Decision (2026-10-10 implementation): Preserve the existing generic value-based JSON encoding order; omit absent members without switching to direct generic encoding. Add one detailed fixture and retain the four basic objects byte-for-byte. Prometheus counts use exact integer text so lifetime counts are not rounded through Double; numeric semantics are unchanged. Use a strict bounded IntMap of noncumulative bin counts per locked slot, then accumulate at sampling time. Expose slotMisses as a read-only diagnostic on the handle. These choices preserve basic wire bytes, exact count arithmetic and synchronized identity/start publication without a new dependency.

- Decision (2026-10-10): Remove nonexistent primitive atomic APIs, publish complete slots under per-slot locks, make cleanup exception-safe, and keep detailed accounting opt-in. Zero-allocation claims require measurement, not prose.
  This revision supersedes conflicting 2026-09-30 design assumptions below.

- Decision: Keep `runSupervised` and `runSupervisedBatch` at their current types and add
  `runSupervisedWith` and `runSupervisedBatchWith` that take a `MetricsDetail`; the old names
  delegate with `defaultMetricsDetail`.
  Rationale: The paired comparator rejects any harness SHA mismatch, and the lifecycle-load
  harness in `shibuya-core-bench/bench/Bench/Lifecycle.hs` calls `runSupervised` directly.
  Changing that signature would force a harness edit and make the baseline-versus-candidate
  comparison impossible by construction. Delegating through one default constant also lets a
  single flipped constant measure the detailed level with the unchanged harness.
  The 2026-10-10 update keeps the released default basic regardless of this diagnostic.
  Date: 2026-09-30

- Decision: Encode the `+Inf` bucket only in Prometheus text; the JSON `buckets` list carries
  the eighteen finite bounds and `count` is the total.
  Rationale: Aeson encodes a non-finite `Double` as a string, which would make the `le`
  member heterogeneously typed; the total is already present as `count`.
  Date: 2026-09-30

- Decision: Emit the `shibuya_processor_oldest_in_flight_seconds` gauge only while a
  processor has an `oldestInFlight` value.
  Rationale: The sampled record does not carry the detail level, and a fabricated `0` for a
  basic processor would violate the contract in
  `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`;
  Prometheus staleness handling makes a disappearing series ordinary.
  Date: 2026-09-30

- Decision: Measure with a focused budgets file that narrows only `requiredScenarios` to the
  focused measured scenarios and changes no limit, pair count, confidence level, or seed.
  Rationale: `scripts/audit/compare-performance.ts` reports every missing required scenario
  as an error, so the canonical file cannot judge a focused subset; the release-level full
  matrix stays the release owner's gate.
  Date: 2026-09-30


## Outcomes & Retrospective


Functional implementation is delivered in `b7567a2` with the basic-path correction in `67f00ec`. Latency and oldest-in-flight detail are opt-in, exposed through JSON, Prometheus and WebSocket, and documented with ADR-0009 and capability evidence. The shipped default remains basic.

Against baseline `db8e783`, the corrected focused basic matrices each pass 68 of 69 cells. The remaining `-N1` serial-full-inbox live-memory ratio is 1.0083 (95% CI 0.9606–1.0591); the `-N4` retry-path throughput adverse ratio is 1.0244 (95% CI 0.9699–1.0815). Both intervals cross the 1.05 limit, so neither matrix is accepted. Higher-concurrency `-N4` diagnostics also remain inconclusive. Measurements used GHC 9.12.4, O2, MacBookPro18,2, identical harnesses and external solver identities, and unchanged budgets.

Detailed diagnostics show the opt-in cost: serial allocation increases about 47% under `-N1` and 46% under `-N4`, with throughput about 27% and 14% lower. Batch allocation increases about 0.4%. In real WebSocket fan-out at 1/16/64 clients, all thirty detailed runs completed 500,000 observations with zero slot misses and no retained oldest attempt; allocation increased about 55/58/72% and throughput fell about 23/22/23% (O1, `-N4`, ten alternating pairs). These are workload diagnostics, not an acceptance claim.

The functional tests need no expansion. EP-49 is Complete under the revised implementation validation scope; EP-50 may proceed. The old inconclusive performance results remain inconclusive and do not certify a release. Any future release certification needs its own quiet-host stability control under ADR-0002. Raw scratch artifacts were removed from the project at the user's request; this summary does not substitute for candidate-bound release evidence.


## Context and Orientation


Shibuya is a supervised queue-processing library. An application declares processors; each
processor pulls messages from an adapter, hands them to a handler, and finalizes them with an
acknowledgement decision. A hot path is code that runs once per message; anything added there
is multiplied by throughput, so this repository budgets it. Allocation means heap memory
requested per message, which the garbage collector must later reclaim; the benchmark harness
reports it as allocated bytes per message. A monotonic clock is a clock that only moves
forward regardless of wall-clock adjustments; `GHC.Clock.getMonotonicTimeNSec` returns it as
nanoseconds in a `Word64`. CAS, compare-and-swap, is an atomic instruction that writes a new
value into a memory cell only if the cell still holds an expected old value; it lets several
threads claim distinct cells without a lock. A histogram bucket counts observations whose
value is at most the bucket's upper bound; Prometheus buckets are cumulative, so each bucket
includes every smaller bucket, and the last bucket, labelled `+Inf`, equals the total count.
A shard is one of several copies of a counter, each updated by a subset of writers, whose sum
is the logical value; sharding avoids many threads hammering one cache line. An in-flight
slot is one preallocated cell that holds the start time and identity of one message from the
moment its handler starts until it is finalized.

The metrics write path lives in `shibuya-core/src/Shibuya/Core/Metrics.hs`. `HotCounters`
holds four `AtomicCounter`s (`received`, `processed`, `failed`, `inFlight`) updated by
fetch-and-add on the message path. `MetricsHandle` holds those counters plus
`maxConcurrencyRef`, `burstStartedRef`, `lastProgressRef`, a monotonic origin
(`progressOriginNs`, `progressOriginTime`), an injectable `progressClock :: IO Word64`, the
sampler's `lastObservedProgress`, `stateActiveRef`, and the cold `TVar ProcessorMetrics`.
`newMetricsHandle now` calls `newMetricsHandleWithClock getMonotonicTimeNSec now`.
`sampleMetrics` reads the cold snapshot, the four counters, and `maxConcurrencyRef`, calls
`observeProgress` (which reads the clock only when the processed, failed, in-flight tuple
changed since the last sample and restamps the burst start on an observed zero-to-positive
in-flight transition), converts monotonic nanoseconds to `UTCTime` with `monotonicToUTC`,
and returns the cold record with its `state` and `stats` replaced: cold `Failed` or `Stopped`
wins, otherwise a positive in-flight count means `Processing` and zero means `Idle`. That
sampler-side design exists because `docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`
measured a direct per-handler clock design, two clock reads per message stored in boxed
`IORef`s, at 28% slower on the serial no-op benchmark and 12% slower on the async one, and
rejected it. This plan needs two clock reads per message by definition, so it measures synchronized detailed accounting and keeps the default basic.

`beginProcessing handle maxConcurrency` fetch-adds `inFlight`, records the concurrency bound
and marks the handle active when the count reaches one, and returns the new count.
`finishProcessing handle result` bumps `processed` or `failed` according to the
`AckDecisionMetric` (`CountProcessed`, `CountFailed`, `CountNeither`, `CountHalt reason`),
decrements `inFlight` with an underflow floor, and writes cold `Failed` for a handler failure
or a halt. `finishFinalizationFailure` is `finishProcessing` with a `Left`.
`recordBatchOutcomeMetrics` is the batch equivalent: it adds per-message deltas, decrements
`inFlight` once for the whole batch, and advances `BatchStats`. `ProcessorMetrics` has the
fields `state`, `stats`, `batch`, and `startedAt` and derives its JSON instances generically,
so its member names are the Haskell field names in camelCase. `ProcessorState` is `Idle`,
`Processing InFlightInfo UTCTime UTCTime`, `Failed Text UTCTime`, or `Stopped`, with
hand-written JSON instances tagged by `status`.

The hook sites are two functions. `processOne` in
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` opens a span, calls
`beginProcessing`, runs the handler under `catchAny` (a handler exception becomes
`AckRetry (RetryDelay 0)`), calls `finalizeWithRetry`, records span status, and then calls
`finishFinalizationFailure` or `finishProcessing` before publishing any exit request.
`processOneBatch` in `shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs` does the
same for one emitted batch: `beginProcessing` once (a batch is one in-flight unit), the batch
handler, one `finalizeWithRetry` per retained message, then `recordBatchOutcomeMetrics`.
`runSupervised` and `runSupervisedBatch` in `Supervised.hs` create the handle with
`newMetricsHandle now`, register it with the master, and start the supervised child;
`runWithMetrics` and `runWithMetricsBatch` are the unsupervised test drivers. `runApp` in
`shibuya-core/src/Shibuya/App.hs` validates `AppConfig` (`strategy`, `inboxSize`) and calls
those runners from `spawnProcessors`.

The read side is `shibuya-metrics`. `shibuya-metrics/src/Shibuya/Metrics/JSON.hs` encodes
`getAllMetricsIO` and `getProcessorMetricsIO` results with `Data.Aeson.encode`, so any new
`ProcessorMetrics` member appears automatically. `shibuya-metrics/src/Shibuya/Metrics/Prometheus.hs`
renders five series by hand (`shibuya_messages_received_total`,
`shibuya_messages_processed_total`, `shibuya_messages_failed_total`,
`shibuya_processor_state`, `shibuya_processor_in_flight`) with a `processor` label and
`escapeLabel`. `shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs` pushes an `update` frame
from its push producer only when a processor's sampled `ProcessorMetrics` differs from the last
value sent. The suite `shibuya-metrics-test` compares
`shibuya-metrics/test/golden/processor-metrics.json.golden` and
`shibuya-metrics/test/golden/prometheus.golden` byte for byte; the fixtures are built in
`shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs` (`fixtureMetrics`, `fixtureProcessor`,
`registerPrometheusFixtures`, `withMaster`, `registerIdleProcessor`). A golden diff without a
recorded decision is a defect in the change.

The contract every addition follows is
`docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`:
published shapes are frozen; additions are optional members and new series; member names are
camelCase, series names snake_case; a `Nothing` member is omitted, never `null`; nothing is
fabricated; and per-message accounting is measured against the paired budgets before it is
accepted, with a disabled path that is itself measured. The budgets and paired protocol are
`docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md` together with
`docs/audits/lifecycle-release/performance-budgets.json` and
`docs/audits/lifecycle-release/README.md`: at most 5% throughput loss, 5% allocation or live
memory growth, and 10% latency growth, at least ten alternating pairs, inconclusive is not a
pass, and no agent waives its own failed cell.
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` defines the
retained lifecycle snapshot and halt-versus-failure semantics; this plan does not change
them. `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` contributes the
rule that a test asserting new behavior must be seen failing before it is trusted.

Two siblings edit `Shibuya.Core.Metrics` after this plan.
`docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md` adds a
`progress` member and consumes `DetailOptions.maxTrackedPartitions`, which this plan defines
now so the type breaks only once. `docs/plans/51-implement-source-level-processor-pause-and-resume.md`
adds a `Paused` constructor to `ProcessorState`; its edits are disjoint in content, and
whichever plan lands second rebases on the first.

The proposed `Data.Primitive.ByteArray.casIntArray` and `fetchAddIntArray` are not
exports of primitive 0.9.1.0 (verified in its cached source after Mori returned no project).
Do not add that dependency for these nonexistent APIs. Start with synchronized bounded
slots using `base` MVars and existing containers; any later low-level optimization must
identify real APIs through Mori, verify releases, and prove its memory-ordering protocol.

## Plan of Work


### Milestone 1: accounting behind a switch, measured, with the default fixed


At the end of this milestone the core tracks per-message duration and per-slot start times
for a detailed handle, exposes them through `sampleMetrics` as `latency` and
`oldestInFlight`, costs a basic handle one field read and a branch per message, and ships a
basic default retained, with historical diagnostic overhead recorded. Nothing is exposed over HTTP yet; proof is the
core test suite; EP-52 records the scoped final remote comparison.

Add the types to `shibuya-core/src/Shibuya/Core/Metrics.hs` and export them. `MetricsDetail`
is `MetricsBasic | MetricsDetailed !DetailOptions`; `DetailOptions` is a record with
`maxTrackedPartitions :: !Int`, `defaultDetailOptions = DetailOptions 256`, and
`defaultMetricsDetail :: MetricsDetail` is the single constant that Milestone 1's measurement
records, initially and finally `MetricsBasic`. `LatencyBucket` is `{ le :: !Double, count :: !Integer }`; `LatencySummary` is
`{ count :: !Integer, sumSeconds :: !Double, buckets :: ![LatencyBucket] }` where `buckets` is
cumulative over `latencyBucketBoundsSeconds = [0.0001, 0.00025, 0.0005, 0.001, 0.0025,
0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60]`; keep a parallel
`latencyBucketBoundsNs :: [Word64]` for the hot path so no floating-point work happens per
message, and a parallel `latencyBucketLabels :: [Text]` (`"0.0001"` through `"60"` and
`"+Inf"`) for Prometheus. `OldestInFlight` is `{ messageId :: !MessageId, startedAt ::
!UTCTime, ageSeconds :: !Double }`. All three derive `Eq`, `Show`, `Generic`, and generic
`ToJSON`/`FromJSON`. `ProcessorMetrics` gains `latency :: !(Maybe LatencySummary)` and
`oldestInFlight :: !(Maybe OldestInFlight)`, both `Nothing` in `emptyProcessorMetrics`, and
its instances become `toJSON = genericToJSON omitNothingOptions` and `parseJSON =
genericParseJSON omitNothingOptions` with `omitNothingOptions = defaultOptions
{omitNothingFields = True}`, so a basic processor's JSON is byte-identical to today. In
`shibuya-core/src/Shibuya/Core/Types.hs` add `ToJSON` and `FromJSON` to `MessageId`'s
newtype-deriving list; confirm first with a search that no instance exists anywhere.

Add the slot table. `InFlightSlots` is abstract and contains exactly `max 1 maxConcurrency`
slots, each protected by its own `MVar`, plus a diagnostic miss counter. A slot contains
an optional `(MessageId, Word64)` start and a strict histogram accumulator: eighteen finite
buckets, overflow, total count, and an `Integer` nanosecond sum. Zero is a valid monotonic
timestamp, never a free-slot sentinel. Bounds are `Word64`, not machine-sized signed Int.
Counters and sums use `Integer` to avoid lifetime overflow. The slot is also its histogram
shard; a lock protects a short publication or sample, never a handler or finalizer. No claim
of zero allocation or constant-time scanning is made: scanning is O(concurrency) and must
be measured at 1, 4, 64, and 256 concurrent handlers before considering an optimization.

`MetricsHandle` gains `detail :: !MetricsDetail` and `slots :: !(Maybe InFlightSlots)`.
`newMetricsHandleWith detail maxConcurrency now` and the clock-injected variant allocate
slots only for `MetricsDetailed`. Existing `newMetricsHandle` and `newMetricsHandleWithClock`
keep their signatures and mean basic. Validate positive concurrency and nonnegative
`maxTrackedPartitions` before acquiring resources; zero partitions means latest-only tracking.

`claimInFlightSlot` returns -1 for a basic handle; otherwise read the clock and claim the
first free slot under that slot's MVar, publishing identity and timestamp together. Exhaustion
increments the diagnostic miss count and returns -1, but any miss in a supported runner is
a correctness failure in tests. `releaseInFlightSlot` reads the end clock, then under the
owned slot's MVar clears the start and records one completed handler-plus-finalization
observation. `abandonInFlightSlot` clears ownership without recording a completed duration.
Both ignore -1. Use masked ownership transfer around claim and cleanup, restore cancellation
for the processing action, abandon on exceptional exit, and release exactly once on normal
exit. Never put this bracket on the basic path. Do not swallow asynchronous cancellation.
A completed failed finalization is an observation; an interrupted attempt is not.

Make `sampleMetrics` read each slot under its MVar, copy its strict contents, and release
the lock before formatting. Aggregate histogram copies and derive count and cumulative buckets
from the same copies so bucket counts remain ordered and `+Inf == count`. Select the oldest
published start; different slots are sampled at slightly different instants, so this is a
best-effort concurrent observation, not an atomic snapshot of all handlers. Identity and start
within a slot must always match. A basic handle reads no slot or detail clock.

In `processOne`, bracket detailed ownership immediately after `beginProcessing` through
completion of finalization and metrics accounting. In the specialized `processOneBatchWithDetail` worker, claim with the first
retained message identity and release after `recordBatchOutcomeMetrics`. The histogram measures
one processing attempt in serial/message mode and one emitted batch in batch mode, including
finalization retries. Document these units on JSON and Prometheus; it is not handler-only
latency or adapter queue wait. Cancellation at every hook boundary must leave no occupied slot.

Add `runSupervisedWith` and `runSupervisedBatchWith` with a leading `MetricsDetail` argument.
Existing runner signatures delegate with `defaultMetricsDetail = MetricsBasic`; `runWithMetrics`
and `runWithMetricsBatch` remain basic. `AppConfig.metricsDetail` also defaults to the same
constant, and `spawnProcessors` calls the `With` variants. Re-export the new public types
and constructors through `Shibuya`. Update every direct metrics/config record construction.
No dependency is added for this prototype.


Write the unit tests in a new `shibuya-core/test/Shibuya/Core/MetricsSpec.hs`, listed in
`other-modules` of `shibuya-core-test` and in `shibuya-core/test/Main.hs`, using
`newMetricsHandleWithClockAndDetail` with an `IORef`-backed clock: claiming returns distinct
slots up to the bound and `-1` beyond it while `slotMisses` counts one; releasing a slot after
advancing the clock by 3 ms lands exactly in the `0.005` bucket and every larger bucket of the
cumulative summary, with `count` 1 and `sumSeconds` 0.003; `latency` is `Nothing` before any
release; with two slots claimed at different clock values the sampler names the earlier
message and its age equals the clock difference; a basic handle returns `Nothing` for both
members and never touches the clock (assert the clock call count before and after the detail hooks; the existing basic sampler may read
its progress clock). Add deterministic races for claim/publication/release and cancellation
at every ownership boundary, timestamp zero, repeated slot reuse, and a duration over 60
seconds whose finite buckets remain zero but overflow/count increment. Write each test before its
implementation and record the failing run.

Historical detailed diagnostics and inconclusive basic matrices are retained in Outcomes. Per-child repeated measurement is superseded by the owner-requested single final remote quick comparison under EP-52. Basic remains the default; functional acceptance here is the core suite and deterministic detailed-accounting tests.


### Milestone 2: exposure over JSON, Prometheus, and WebSocket, with fixtures and runner tests


At the end of this milestone every read surface of `shibuya-metrics` carries the new data,
the golden fixtures record it deliberately, and the runner-level tests demonstrate the
user-visible behavior. Proof is `cabal test shibuya-metrics --test-show-details=direct` and
`cabal test shibuya-core` green, plus a `curl` transcript.

JSON needs no encoder change beyond Milestone 1, but the fixtures must show it. In
`TestSupport.hs` extend `fixtureProcessor` for the two new fields (`Nothing`) and add a fifth
entry `detailed` to `fixtureMetrics` with a hand-built `LatencySummary` (count 3, sum 0.42,
cumulative buckets rising to 3 at `0.25`) and `OldestInFlight (MessageId "m-7") (at 40)
12.5`; regenerate `processor-metrics.json.golden`, inspect the diff, and confirm that the four
existing objects are unchanged and the new object's members are camelCase with `buckets` as
an array of `{le, count}` objects.

In `Prometheus.hs` add, after the existing series, `shibuya_message_processing_seconds` as a
histogram: for every processor whose `latency` is `Just`, one
`shibuya_message_processing_seconds_bucket{processor="…",le="…"}` line per label in
`latencyBucketLabels` (cumulative, with `+Inf` equal to `count`), then
`shibuya_message_processing_seconds_sum{processor="…"}` in seconds and
`shibuya_message_processing_seconds_count{processor="…"}`; emit the `HELP` and `TYPE
histogram` lines once even when no processor has a summary. Add
`shibuya_processor_oldest_in_flight_seconds` as a gauge emitted only for processors whose
`oldestInFlight` is `Just`, with the age. In `registerPrometheusFixtures` add a fifth handle
built with `newMetricsHandleWithClockAndDetail` and an `IORef` clock: claim a slot at clock
0 for `MessageId "m-1"`, advance to 3,000,000 ns, release, then claim a second slot at
5,000,000 ns and advance the clock to 17,500,000 ns before the request so the gauge shows
`0.0125` and the histogram shows one observation in the `0.005` bucket. Regenerate
`prometheus.golden` and confirm the existing series are byte-identical. Prove both fixtures
can fail by renaming `sumSeconds` in a scratch worktree and recording the failing golden
examples.

In `WebSocket.hs` the push producer compares `fmap stableView` of the prior sample with
`Just (stableView metrics)`,
where `stableView` replaces `ageSeconds` by 0 inside `oldestInFlight`, so a stuck processor
does not push an update every interval; document in the Haddock of `Shibuya.Metrics` that a
client extrapolates age from the last frame's `ageSeconds` and its own clock. Add a
`WebSocketSpec` case: register a detailed handle, connect, claim a slot, then advance the
injected clock twice without other changes and assert with `timeout` that no second update
arrives, then release the slot and assert an update whose `oldestInFlight` is absent and
whose `latency.count` is 1. Add a `TypesSpec` case decoding a pre-existing `update` frame
without the new members.

Runner tests go in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`, using
`runSupervisedWith (MetricsDetailed defaultDetailOptions)` and `getProcessorMetricsIO`. A
handler that blocks on an `MVar` until the test releases it: after the handler starts,
sample twice with a real delay between samples and assert `oldestInFlight.ageSeconds` grew
and `messageId` matches; release, wait for `done`, and assert `oldestInFlight` is `Nothing`
and `latency.count` is 1 with `sumSeconds` at least the delay. An `Async 4` processor whose
handlers block on four separate `MVar`s released in reverse order: after all four start, the
oldest must be the first message; after releasing it, the oldest must be the second. A batch
processor built with `mkBatchProcessor` through `runApp` with `metricsDetail = MetricsDetailed
defaultDetailOptions`: `latency.count` equals the number of emitted batches, not messages.
RTS allocation diagnostics already recorded in Outcomes remain historical, not release acceptance. The bounded final remote comparison belongs to EP-52.


Temporarily configure the example AppConfig with `metricsDetail = MetricsDetailed
defaultDetailOptions`, then run `cabal run shibuya-example`, then `curl -s
http://127.0.0.1:9090/metrics/<processorId> | jq .latency` and paste the object into
Concrete Steps.


### Milestone 3: durable records


At the end of this milestone the design is explained where the next contributor will look.
Create `docs/adr/<next>-account-for-in-flight-detail-and-latency-with-bounded-synchronized-slots-behind-an-opt-in-detail-level.md`
at the next unused four-digit number, in the plain-Markdown format of
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` (title, Status,
Date, Context, Decision, Consequences, Evidence): the slot table, the sharded histogram, the
`MetricsDetail` switch, the basic default and measured detailed overhead, the age-zeroed WebSocket
projection, the `+Inf` and gauge decisions above, and a sentence that
`docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md` extends
the record with a bounded partition table. Add a "Latency and in-flight detail" section to
`docs/architecture/METRICS.md` with the new types, the JSON shape, and the Prometheus series.
Update the Haddock of `Shibuya.Core.Metrics` and the module header of
`shibuya-metrics/src/Shibuya/Metrics.hs`. Add a `metricsDetail` paragraph to
`docs/user/getting-started.md` (the user guide; `docs/USAGE_GUIDE.md` is only an index)
next to its `AppConfig` description. In `docs/capabilities/` add module and test
evidence rows for the new accounting to CAP-9 (`processor-introspection.md`) and for the new
series and members to CAP-10 (`metrics-endpoints.md`), advance their timestamps, append with
`okf log add`, and validate. Append to `CHANGELOG.md`, `shibuya-core/CHANGELOG.md`, and
`shibuya-metrics/CHANGELOG.md` under an `Unreleased` heading: breaking for direct construction
of `AppConfig` and `ProcessorMetrics`; additive for
the `latency` and `oldestInFlight` members, the `MessageId` JSON instances, the histogram and
gauge series, and the new public functions. Do not choose a version.


## Concrete Steps


Run everything from the repository root. Before editing, search for existing JSON instances:

```bash
rg 'instance.*JSON.*MessageId' shibuya-core/src shibuya-metrics/src
```


Expected: no existing MessageId JSON instances. Build and test after each milestone:


```bash
cabal build all
cabal test shibuya-core
cabal test shibuya-metrics --test-show-details=direct
nix fmt
```

`cabal test shibuya-core` runs `shibuya-core-test`, `shibuya-core-gc-test`, and
`shibuya-core-gc-finished-test`; all three must pass. Performance validation follows the user’s 2026-10-12 instruction to use the existing remote fast lane and avoid overengineering. Run one bounded exact-revision comparison for the integrated candidate through `mori://shinzui/keiro-runtime-kenshou/okf/runbooks/concepts/RB-2`, using the supplied `shibuya-core-quick` profile and the runbook’s prepare/run/verify workflow. Baseline is the clean pre-initiative commit; candidate is the final committed implementation. Keep request, exact revisions, harness identity, session/receipt and report references in EP-52. Use temporary or Kenshou-owned scratch storage for raw output, not a new Shibuya audit framework. Do not expand profiles, run calibration batches, add benchmark variants, or repeat statistically valid results to chase a pass. The current quick profiles are uncalibrated: use `purpose: calibration`, report `gatingEligible: false`, and do not call an exploratory result release certification. Report regressions, incomplete coverage and infrastructure failures plainly. Functional child acceptance no longer waits for per-child performance matrices; release certification remains separate under ADR-0002. MetricsBasic stays the default; deterministic feature tests establish detailed cursor and timing correctness. This scope supersedes the older local full-matrix and observer-load prescriptions for this implementation.

Milestone 2 transcript to capture with the example explicitly configured detailed:

```bash
cabal run shibuya-example &
sleep 3
curl -s http://127.0.0.1:9090/metrics | jq 'to_entries[0].value | {latency, oldestInFlight}'
curl -s http://127.0.0.1:9090/metrics/prometheus | grep -E 'processing_seconds|oldest_in_flight'
```

Expected: a `latency` object with `count`, `sumSeconds`, and eighteen `buckets`, and
histogram bucket lines labelled `le="+Inf"` whose value equals the `_count` line. Milestone 3
records:

```bash
okf log add docs/capabilities CAP-9 --kind Update -m "Record slot-based in-flight detail and sharded latency accounting evidence"
okf log add docs/capabilities CAP-10 --kind Update -m "Record latency and oldest-in-flight members and series evidence"
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
```

Every commit carries these trailers:

```text
MasterPlan: docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md
ExecPlan: docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md
Intention: intention_01m3ta8zgtebmaz00g0snjzy5a
```


## Validation and Acceptance


After one message has completed on a detailed processor, `GET /metrics/<processorId>`
returns a `latency` member with `count` 1, a positive `sumSeconds`, and eighteen `buckets`
whose counts are non-decreasing (the 60-second bucket need not equal count for longer attempts), and `GET /metrics/prometheus` contains
`shibuya_message_processing_seconds_bucket{processor="<id>",le="+Inf"} 1.0`,
`shibuya_message_processing_seconds_count{processor="<id>"} 1.0`, and a matching `_sum`.
While a handler is deliberately blocked, two fetches a second apart return `oldestInFlight`
objects with the same `messageId` and `startedAt` and an `ageSeconds` that grew by about one;
after acknowledgement the member is absent. A basic processor's JSON is byte-identical to
the 0.10.0.0 shape. A WebSocket client written against the shipped frames decodes every
`update`, and a stuck processor produces no update while only its age changes. Under
`Async 4` with four blocked handlers the reported oldest message is the first one started.
A batch processor reports one latency observation per batch.

`cabal test shibuya-core` and `cabal test shibuya-metrics` pass with the new examples
counted; the `MetricsSpec` examples, the two golden examples, and the `WebSocketSpec` age
example were each observed failing before their implementation or by mutation, and the
failing runs are recorded in Surprises & Discoveries with seeds. The integrated remote quick comparison is recorded by EP-52. Existing detailed cost diagnostics remain explicit and the shipped default stays MetricsBasic. The ADR, architecture
section, Haddock, usage guide, capability records, and three changelogs exist and the
capability bundle validates.


## Idempotence and Recovery


Every command above is safe to rerun. Golden regeneration overwrites the fixture files;
review the diff before committing and revert with `git checkout -- shibuya-metrics/test/golden`
if it contains anything undecided. Measurement worktrees are disposable; remove and recreate
them if a build is interrupted. Diagnostic output under `/tmp/shibuya-ep49-measurements/` stays outside the repository.
Preserve distinct captures when rerunning; summarize the result in this plan. If a basic cell fails, profile the hot path (a ticky profile of `processOne` is the
quickest tool), fix the cause, commit, and capture again from the new commit; never edit a
budget or reinterpret an inconclusive result. Do not introduce a low-level dependency without verified APIs and new measurements. Work on the current branch and
commit small conventional changes with the trailers above.


## Interfaces and Dependencies


No new dependency is required by the synchronized-slot prototype.


New and changed interfaces in `Shibuya.Core.Metrics`, all exported:

```haskell
data MetricsDetail = MetricsBasic | MetricsDetailed !DetailOptions
data DetailOptions = DetailOptions {maxTrackedPartitions :: !Int}
defaultDetailOptions :: DetailOptions          -- DetailOptions 256
defaultMetricsDetail :: MetricsDetail          -- MetricsBasic throughout this initiative
data LatencyBucket = LatencyBucket {le :: !Double, count :: !Integer}
data LatencySummary = LatencySummary {count :: !Integer, sumSeconds :: !Double, buckets :: ![LatencyBucket]}
latencyBucketBoundsSeconds :: [Double]
latencyBucketLabels :: [Text]
data OldestInFlight = OldestInFlight {messageId :: !MessageId, startedAt :: !UTCTime, ageSeconds :: !Double}
data ProcessorMetrics = ProcessorMetrics
  { state :: !ProcessorState, stats :: !StreamStats, batch :: !BatchStats, startedAt :: !UTCTime,
    latency :: !(Maybe LatencySummary), oldestInFlight :: !(Maybe OldestInFlight) }
data InFlightSlots                              -- abstract; fields internal
data MetricsHandle = MetricsHandle { {- existing fields -} , detail :: !MetricsDetail, slots :: !(Maybe InFlightSlots)}
newMetricsHandleWith :: MetricsDetail -> Int -> UTCTime -> IO MetricsHandle
newMetricsHandleWithClockAndDetail :: IO Word64 -> MetricsDetail -> Int -> UTCTime -> IO MetricsHandle
metricsDetailLevel :: MetricsHandle -> MetricsDetail         -- OPAQUE; read outside the loop
claimInFlightSlot :: MetricsHandle -> MessageId -> IO Int      -- INLINE; -1 when basic or full
releaseInFlightSlot :: MetricsHandle -> Int -> IO ()           -- no-op for -1
abandonInFlightSlot :: MetricsHandle -> Int -> IO ()           -- cancellation cleanup
```

`beginProcessing`, `finishProcessing`, `finishFinalizationFailure`, `recordBatchOutcomeMetrics`,
`newMetricsHandle`, `newMetricsHandleWithClock`, and `sampleMetrics` keep their types. In
`Shibuya.Core.Types`, `MessageId` gains newtype-derived `ToJSON` and `FromJSON`. In
`Shibuya.Internal.Runner.Supervised`:

```haskell
runSupervisedWith :: (IOE :> es, Tracing :> es) => MetricsDetail -> Master -> Natural -> ProcessorId -> OrderingPolicy -> Concurrency -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor
runSupervisedBatchWith :: (IOE :> es, Tracing :> es) => MetricsDetail -> Master -> Natural -> ProcessorId -> Concurrency -> BatchConfig es msg -> Adapter es msg -> BatchHandler es msg -> Eff es SupervisedProcessor
runSupervised = runSupervisedWith defaultMetricsDetail
runSupervisedBatch = runSupervisedBatchWith defaultMetricsDetail
```

In `Shibuya.App`, `AppConfig` gains `metricsDetail :: !MetricsDetail` and `defaultAppConfig`
sets it to `defaultMetricsDetail`; `Shibuya` re-exports the new types and constants. In
`shibuya-metrics`: `Shibuya.Metrics.Prometheus` renders the histogram and gauge;
the `Shibuya.Metrics.WebSocket` push producer compares the age-zeroed projection; no exported
signature changes. Tests use `Test.Hspec`, `Network.Wai.Test`, `Warp.testWithApplication`,
and `Network.WebSockets` as the existing suites do.

Ownership: this plan owns `MetricsDetail`, `DetailOptions`, the omit-`Nothing` encoder
options, the slot table, the hook points in `processOne` and `processOneBatchWithDetail`, the
`runSupervisedWith` pair, and the golden fixtures for the new members; `docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md`
extends them and must not redefine them. `docs/plans/51-implement-source-level-processor-pause-and-resume.md`
edits the same module for a different concern; implement the two sequentially in either
order and rebase the second. Coordination context is
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`.


Revision note (2026-10-10): API and performance review applied. Remove nonexistent primitive atomic APIs, publish complete slots under per-slot locks, make cleanup exception-safe, and keep detailed accounting opt-in. Zero-allocation claims require measurement, not prose. Functional implementation is delivered; performance acceptance remains pending.


Revision note (2026-10-12): Replace per-child/full-matrix performance work with the owner-requested existing bounded remote quick workflow, preserve historical uncertainty, and keep release certification separate.
