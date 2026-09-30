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

The message hot path is protected. The new accounting stores its timestamps unboxed in
preallocated arrays, uses no shared lock, allocates nothing per message, and lives behind a
`MetricsDetail` switch on `AppConfig` whose disabled path costs one field read and a branch.
The shipped default is whichever level the repository's paired performance harness accepts.
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


- [ ] Milestone 1, accounting: add `MetricsDetail`, `DetailOptions`, `defaultMetricsDetail`, `LatencySummary`, `LatencyBucket`, `OldestInFlight`, the slot table, and the sharded histogram to `shibuya-core/src/Shibuya/Core/Metrics.hs`; add `primitive` to `shibuya-core.cabal`.
- [ ] Milestone 1, hooks: add `claimInFlightSlot` and `releaseInFlightSlot`; call them from `processOne` and `processOneBatch`; add `runSupervisedWith` and `runSupervisedBatchWith`; add `metricsDetail` to `AppConfig`.
- [ ] Milestone 1, unit tests: `shibuya-core/test/Shibuya/Core/MetricsSpec.hs` for claim, release, bucketing, torn-sample retry, and sampling with an injected clock; suite green.
- [ ] Milestone 1, measurement: paired capture of baseline, basic candidate, and detailed diagnostic under `-N1` and `-N4`; verdicts recorded under `docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/`.
- [ ] Milestone 1, default: `defaultMetricsDetail` set from the verdict; decision recorded below.
- [ ] Milestone 2, JSON: `ProcessorMetrics` encoders omit `Nothing` members; `MessageId` JSON instances; golden fixture gains a detailed processor.
- [ ] Milestone 2, Prometheus: `shibuya_message_processing_seconds` histogram and `shibuya_processor_oldest_in_flight_seconds` gauge; golden updated deliberately.
- [ ] Milestone 2, WebSocket: `sendIfChanged` compares an age-zeroed projection; update frame test.
- [ ] Milestone 2, runner tests: blocked handler age growth and clearing, `Async 4` oldest identification, batch processor duration, tasty-bench allocation check on the basic path.
- [ ] Milestone 3, records: ADR, `docs/architecture/METRICS.md`, Haddock, `docs/user/getting-started.md`, CAP-9 and CAP-10 evidence with `okf log add`, three changelogs.


## Surprises & Discoveries


(None yet.)


## Decision Log


- Decision: Keep `runSupervised` and `runSupervisedBatch` at their current types and add
  `runSupervisedWith` and `runSupervisedBatchWith` that take a `MetricsDetail`; the old names
  delegate with `defaultMetricsDetail`.
  Rationale: The paired comparator rejects any harness SHA mismatch, and the lifecycle-load
  harness in `shibuya-core-bench/bench/Bench/Lifecycle.hs` calls `runSupervised` directly.
  Changing that signature would force a harness edit and make the baseline-versus-candidate
  comparison impossible by construction. Delegating through one default constant also lets a
  single flipped constant measure the detailed level with the unchanged harness.
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
  eight measured scenarios and changes no limit, pair count, confidence level, or seed.
  Rationale: `scripts/audit/compare-performance.ts` reports every missing required scenario
  as an error, so the canonical file cannot judge a focused subset; the release-level full
  matrix stays the release owner's gate.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)


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
rejected it. This plan needs two clock reads per message by definition, so it stores them
unboxed and measures before choosing a default.

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
from `sendIfChanged` only when a processor's sampled `ProcessorMetrics` differs from the last
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

The `primitive` package supplies `Data.Primitive.ByteArray` (unboxed mutable arrays with
`casIntArray` and `fetchAddIntArray`) and `Data.Primitive.SmallArray`. It is not registered
in the Mori registry, so read it from the local Cabal store after building. At planning time
Hackage's preferred versions list 0.9.1.0 as the newest release and the repository's current
solver plan already resolves `primitive-0.9.1.0` through `streamly`, so declaring
`primitive ^>=0.9` adds a direct edge without changing the dependency solution. Verify both
facts again before editing the Cabal file.


## Plan of Work


### Milestone 1: accounting behind a switch, measured, with the default fixed


At the end of this milestone the core tracks per-message duration and per-slot start times
for a detailed handle, exposes them through `sampleMetrics` as `latency` and
`oldestInFlight`, costs a basic handle one field read and a branch per message, and ships a
default level justified by paired evidence. Nothing is exposed over HTTP yet; proof is the
core test suite plus the comparator verdict files.

Add the types to `shibuya-core/src/Shibuya/Core/Metrics.hs` and export them. `MetricsDetail`
is `MetricsBasic | MetricsDetailed !DetailOptions`; `DetailOptions` is a record with
`maxTrackedPartitions :: !Int`, `defaultDetailOptions = DetailOptions 256`, and
`defaultMetricsDetail :: MetricsDetail` is the single constant that Milestone 1's measurement
fixes. `LatencyBucket` is `{ le :: !Double, count :: !Int }`; `LatencySummary` is
`{ count :: !Int, sumSeconds :: !Double, buckets :: ![LatencyBucket] }` where `buckets` is
cumulative over `latencyBucketBoundsSeconds = [0.0001, 0.00025, 0.0005, 0.001, 0.0025,
0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60]`; keep a parallel
`latencyBucketBoundsNs :: [Int]` for the hot path so no floating-point work happens per
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

Add the slot table. `InFlightSlots` holds `slotCount`, `shardCount = min slotCount 16`, a
`MutableByteArray RealWorld` of `slotCount` `Int` start timestamps (0 means free), a
`SmallMutableArray RealWorld MessageId` of the same length initialised with the sentinel
`MessageId ""`, a `MutableByteArray RealWorld` histogram laid out as `shardCount` groups of
21 `Int`s (18 finite buckets, one overflow bucket, one nanosecond sum, one count), and an
`AtomicCounter` `slotMisses`. Bucket counters are raw, not cumulative; the sampler
accumulates. `MetricsHandle` gains `detail :: !MetricsDetail` and `slots :: !(Maybe
InFlightSlots)`. `newMetricsHandleWith detail maxConcurrency now` and
`newMetricsHandleWithClockAndDetail clock detail maxConcurrency now` build the table only for
`MetricsDetailed`, with `slotCount = max 1 maxConcurrency`; `newMetricsHandle` and
`newMetricsHandleWithClock` keep their types and mean `MetricsBasic`.

Add the hooks. `claimInFlightSlot handle messageId` returns `-1` immediately when `slots`
is `Nothing`; otherwise it reads the monotonic clock once, scans slots from 0 with
`casIntArray` expecting 0 and writing the timestamp, writes the message id beside the first
slot it wins, and returns its index; if no slot is free it fetch-adds `slotMisses` and
returns `-1`. `releaseInFlightSlot handle slot` returns at once for `-1`; otherwise it reads
the clock, computes the duration in nanoseconds from the slot's start, picks the bucket by
scanning `latencyBucketBoundsNs`, fetch-adds that bucket, the sum, and the count in shard
`slot mod shardCount`, writes the sentinel id, and writes 0 to the start cell last so a
sampler never sees a live id on a free slot. Mark both `INLINE`. Under `Async n`, `Ahead n`,
and the keyed scheduler the in-flight count never exceeds the bound, and Serial is 1, so
`slotCount = max 1 maxConcurrency` suffices; `slotMisses` exists to prove that.

Make `sampleMetrics` read the table. For a detailed handle: read every start cell, keep the
minimum nonzero; read that slot's id, then re-read the start cell, and accept only if it is
unchanged; on a torn read retry the scan up to three times and otherwise report
`oldestInFlight = Nothing` for this sample. Convert the accepted start with `monotonicToUTC`,
compute `ageSeconds` from `progressClock` now, and build `OldestInFlight`; `Nothing` when no
slot is claimed. Sum the shards into a `LatencySummary` whose `buckets` are cumulative over
the eighteen finite bounds; report `Nothing` until `count` is positive. A basic handle
reports both members `Nothing`.

Wire the hooks. In `processOne`, bind `slot <- liftIO (claimInFlightSlot metricsHandle
messageId)` immediately after `beginProcessing`, and call `releaseInFlightSlot metricsHandle
slot` immediately after the `finishFinalizationFailure` or `finishProcessing` call and
before any `requestProcessorExit`. In `processOneBatch`, claim with `(NE.head
batch).envelope.messageId` after `beginProcessing` and release after
`recordBatchOutcomeMetrics`; a batch therefore reports its whole handler-plus-finalization
duration and the first message of the oldest batch. Add `runSupervisedWith` and
`runSupervisedBatchWith` to `Supervised.hs`, identical to the existing functions except for a
leading `MetricsDetail` argument passed to `newMetricsHandleWith` with the concurrency bound
(`Serial` is 1, `Ahead n` and `Async n` are `n`); define `runSupervised =
runSupervisedWith defaultMetricsDetail` and likewise for batch. `runWithMetrics` and
`runWithMetricsBatch` stay basic. In `App.hs` add `metricsDetail :: !MetricsDetail` to
`AppConfig`, set it to `defaultMetricsDetail` in `defaultAppConfig`, and have
`spawnProcessors` call the `With` variants with `config.metricsDetail`. Re-export
`MetricsDetail (..)`, `DetailOptions (..)`, `defaultDetailOptions`, `defaultMetricsDetail`,
`LatencySummary (..)`, `LatencyBucket (..)`, and `OldestInFlight (..)` from `Shibuya`. Add
`primitive ^>=0.9` to the library `build-depends` in `shibuya-core/shibuya-core.cabal`.
Search the whole repository for direct `AppConfig` and `ProcessorMetrics` record construction
(the metrics test support, the wire-load fixture, and the benches construct
`ProcessorMetrics`) and add the new fields.

Write the unit tests in a new `shibuya-core/test/Shibuya/Core/MetricsSpec.hs`, listed in
`other-modules` of `shibuya-core-test` and in `shibuya-core/test/Main.hs`, using
`newMetricsHandleWithClockAndDetail` with an `IORef`-backed clock: claiming returns distinct
slots up to the bound and `-1` beyond it while `slotMisses` counts one; releasing a slot after
advancing the clock by 3 ms lands exactly in the `0.005` bucket and every larger bucket of the
cumulative summary, with `count` 1 and `sumSeconds` 0.003; `latency` is `Nothing` before any
release; with two slots claimed at different clock values the sampler names the earlier
message and its age equals the clock difference; a basic handle returns `Nothing` for both
members and never touches the clock (assert the clock call count). Write each test before its
implementation and record the failing run.

Then measure. Build the lifecycle-load executable from three sources with one unchanged
harness: the committed baseline (the parent of the Milestone 1 commit, in a detached
worktree), the Milestone 1 commit whose `defaultMetricsDetail` is `MetricsBasic`, and a
diagnostic worktree at the same commit with only that constant flipped to `MetricsDetailed
defaultDetailOptions`, whose patch hash is recorded and which is never committed. Confirm
with `git rev-parse HEAD:shibuya-core-bench` that the harness tree hash is identical in all
three, and confirm that the normalized solver hash is identical (adding the direct
`primitive` edge must not change the external solution). Capture `-N1` and `-N4` with
`scripts/audit/capture-performance-paired.ts` for the eight scenarios named in Concrete
Steps, ten pairs per cell, twenty for any cell the comparator calls inconclusive, and judge
each dataset pair with `scripts/audit/compare-performance.ts` against a focused copy of the
budgets that narrows only `requiredScenarios`. The basic candidate must pass every cell
against the baseline; a failing or inconclusive basic cell is a defect to fix, not a number
to waive. If the detailed diagnostic also passes every cell against the baseline, set
`defaultMetricsDetail = MetricsDetailed defaultDetailOptions`; otherwise leave it
`MetricsBasic`. Either way record the measured detailed cost in the Decision Log now and in
the changelog and ADR in Milestone 3. Keep the raw datasets, verdicts, identities, and
commands under `docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/` with a
`README.md` in the style of `docs/audits/lifecycle-release/artifacts/ep39-metrics-lifecycle/README.md`.
If Milestone 2 or 3 later touches `claimInFlightSlot`, `releaseInFlightSlot`,
`processOne`, or `processOneBatch`, measure again.


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

In `WebSocket.hs` change `sendIfChanged` to compare `stableView old /= stableView metrics`,
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
Finally an allocation check: in `shibuya-core-bench/bench/Bench/HotPath.hs` add
`serial-noop-10000-basic` and `serial-noop-10000-detailed` cases using `runSupervisedWith`
explicitly, keep `serial-noop-10000` unchanged, run the group with `--csv` on the parent of
the Milestone 1 commit and on the candidate, and record that the `serial-noop-10000` and
`serial-noop-10000-basic` allocated-bytes columns match the baseline within 1%.

Run the example: `cabal run shibuya-example`, then `curl -s
http://127.0.0.1:9090/metrics/<processorId> | jq .latency` and paste the object into
Concrete Steps.


### Milestone 3: durable records


At the end of this milestone the design is explained where the next contributor will look.
Create `docs/adr/<next>-account-for-in-flight-detail-and-latency-off-the-allocation-path-behind-a-measured-detail-level.md`
at the next unused four-digit number, in the plain-Markdown format of
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` (title, Status,
Date, Context, Decision, Consequences, Evidence): the slot table, the sharded histogram, the
`MetricsDetail` switch, the measured default with its numbers, the age-zeroed WebSocket
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
of `AppConfig` and `ProcessorMetrics` and for the new `primitive` dependency; additive for
the `latency` and `oldestInFlight` members, the `MessageId` JSON instances, the histogram and
gauge series, and the new public functions. Do not choose a version.


## Concrete Steps


Run everything from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. Confirm the
dependency facts first:

```bash
grep -rn 'instance.*JSON.*MessageId' shibuya-core/src shibuya-metrics/src   # expect: no output
curl -sL https://hackage.haskell.org/package/primitive/preferred.json | head -c 200
grep -o '"pkg-name":"primitive","pkg-version":"[^"]*"' dist-newstyle/cache/plan.json | head -1
```

Expected: the preferred list starts with `0.9.1.0`, and the plan already contains
`primitive-0.9.1.0`. Build and test after each milestone:

```bash
cabal build all
cabal test shibuya-core
cabal test shibuya-metrics --test-show-details=direct
cabal bench shibuya-core-bench --benchmark-options="-p hot-path --stdev 3 --timeout 120 --csv /tmp/ep49-hotpath.csv +RTS -N1 -RTS"
nix fmt
```

`cabal test shibuya-core` runs `shibuya-core-test`, `shibuya-core-gc-test`, and
`shibuya-core-gc-finished-test`; all three must pass. Milestone 1 measurement, with the
identities substituted:

```bash
git worktree add --detach /tmp/ep49-baseline <parent-of-milestone-1-commit>
git worktree add --detach /tmp/ep49-detailed <milestone-1-commit>
# In /tmp/ep49-detailed only: set defaultMetricsDetail = MetricsDetailed defaultDetailOptions.
for tree in /tmp/ep49-baseline . /tmp/ep49-detailed; do (cd "$tree" && git rev-parse HEAD:shibuya-core-bench); done
for tree in /tmp/ep49-baseline . /tmp/ep49-detailed; do (cd "$tree" && cabal build shibuya-core-bench:lifecycle-load && jq -r '.["install-plan"][] | select(.style != "local") | "\(.["pkg-name"])-\(.["pkg-version"])"' dist-newstyle/cache/plan.json | sort -u | shasum -a 256); done
jq '.requiredScenarios = ["serial-small-inbox","serial-full-inbox","ahead-uniform-keys","async-hot-key","async-high-cardinality","batch-size","retry-path","dead-letter-path"]' \
  docs/audits/lifecycle-release/performance-budgets.json \
  > docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/focused-budgets.json
for rts in N1 N4; do
  caps=${rts#N}
  bun scripts/audit/capture-performance-paired.ts \
    --baseline-executable "$(cd /tmp/ep49-baseline && cabal list-bin shibuya-core-bench:lifecycle-load)" \
    --baseline-output docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/baseline-${rts,,}.json \
    --baseline-label ep49-baseline-${rts,,} --baseline-production-sha <parent-sha> \
    --candidate-executable "$(cabal list-bin shibuya-core-bench:lifecycle-load)" \
    --candidate-output docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/basic-${rts,,}.json \
    --candidate-label ep49-basic-${rts,,} --candidate-production-sha <milestone-1-sha> \
    --rts -$rts --capabilities $caps --iterations 10 \
    --scenarios serial-small-inbox,serial-full-inbox,ahead-uniform-keys,async-hot-key,async-high-cardinality,batch-size,retry-path,dead-letter-path \
    --machine-id MacBookPro18,2 --platform Darwin-arm64 --compiler ghc-9.12.4 --optimization O2 \
    --harness-sha <bench-tree-hash> --solver-plan-hash <normalized-solver-hash>
  bun scripts/audit/compare-performance.ts \
    --baseline docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/baseline-${rts,,}.json \
    --candidate docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/basic-${rts,,}.json \
    --budgets docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/focused-budgets.json \
    --output docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/verdict-basic-${rts,,}.json
done
```

Repeat the capture and comparison with the `/tmp/ep49-detailed` executable as the
candidate, labels `ep49-detailed-*`, `--candidate-production-sha <milestone-1-sha>+detailed-default`,
outputs `detailed-*.json` and `verdict-detailed-*.json`. The three tree hashes and the three
solver hashes printed by the loops must be identical; if the solver hash differs, stop and
resolve the dependency difference before capturing. The comparator exits 0 for pass, 1 for
fail, and 2 for inconclusive; a `${rts,,}` expansion needs bash 4 or later, otherwise write
the lowercase names by hand. Remove the worktrees afterwards with `git worktree remove
--force`. The `serial-fixed-rate`, `batch-timeout`, `idle-worker`, observer, and shutdown
scenarios are deliberately outside this focused set; the release-level full matrix remains
the release owner's gate.

Milestone 2 transcript to capture:

```bash
cabal run shibuya-example &
sleep 3
curl -s http://127.0.0.1:9090/metrics | jq 'to_entries[0].value | {latency, oldestInFlight}'
curl -s http://127.0.0.1:9090/metrics/prometheus | grep -E 'processing_seconds|oldest_in_flight'
```

Expected: a `latency` object with `count`, `sumSeconds`, and eighteen `buckets`, and
histogram lines ending in `le="+Inf"` whose value equals the `_count` line. Milestone 3
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
whose counts are non-decreasing and end at 1, and `GET /metrics/prometheus` contains
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
failing runs are recorded in Surprises & Discoveries with seeds. The basic-candidate verdict
files report `pass` for every cell under both `-N1` and `-N4`; the detailed verdict files
exist and the shipped `defaultMetricsDetail` matches them. The tasty-bench allocation
columns for the unchanged serial case match the baseline within 1%. The ADR, architecture
section, Haddock, usage guide, capability records, and three changelogs exist and the
capability bundle validates.


## Idempotence and Recovery


Every command above is safe to rerun. Golden regeneration overwrites the fixture files;
review the diff before committing and revert with `git checkout -- shibuya-metrics/test/golden`
if it contains anything undecided. Measurement worktrees are disposable; remove and recreate
them if a build is interrupted. Datasets under `docs/audits/lifecycle-release/artifacts/ep49-detail-accounting/`
are append-only: a rerun writes new file names rather than overwriting a set the plan already
cites. If a basic cell fails, profile the hot path (a ticky profile of `processOne` is the
quickest tool), fix the cause, commit, and capture again from the new commit; never edit a
budget or reinterpret an inconclusive result. If the `primitive` bound does not solve in
`cabal build all`, do not relax any other bound; report it. Work on the current branch and
commit small conventional changes with the trailers above.


## Interfaces and Dependencies


New dependency: `primitive ^>=0.9` in the library stanza of `shibuya-core/shibuya-core.cabal`
(Hackage newest 0.9.1.0 at planning time; already in the solution through `streamly`).

New and changed interfaces in `Shibuya.Core.Metrics`, all exported:

```haskell
data MetricsDetail = MetricsBasic | MetricsDetailed !DetailOptions
data DetailOptions = DetailOptions {maxTrackedPartitions :: !Int}
defaultDetailOptions :: DetailOptions          -- DetailOptions 256
defaultMetricsDetail :: MetricsDetail          -- fixed by Milestone 1's measurement
data LatencyBucket = LatencyBucket {le :: !Double, count :: !Int}
data LatencySummary = LatencySummary {count :: !Int, sumSeconds :: !Double, buckets :: ![LatencyBucket]}
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
claimInFlightSlot :: MetricsHandle -> MessageId -> IO Int      -- INLINE; -1 when basic or full
releaseInFlightSlot :: MetricsHandle -> Int -> IO ()           -- INLINE; no-op for -1
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
`Shibuya.Metrics.WebSocket.sendIfChanged` compares the age-zeroed projection; no exported
signature changes. Tests use `Test.Hspec`, `Network.Wai.Test`, `Warp.testWithApplication`,
and `Network.WebSockets` as the existing suites do.

Ownership: this plan owns `MetricsDetail`, `DetailOptions`, the omit-`Nothing` encoder
options, the slot table, the hook points in `processOne` and `processOneBatch`, the
`runSupervisedWith` pair, and the golden fixtures for the new members; `docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md`
extends them and must not redefine them. `docs/plans/51-implement-source-level-processor-pause-and-resume.md`
edits the same module for a different concern; implement the two sequentially in either
order and rebase the second. Coordination context is
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`.
