---
id: 50
slug: expose-acknowledged-cursor-progress-per-processor-and-partition
title: "Expose acknowledged cursor progress per processor and partition"
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
---


# Expose acknowledged cursor progress per processor and partition

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An operator watching a Shibuya processor through `GET /metrics/<processorId>` today sees
counters and a state, but not where the processor has got to in its source. Every message
carries an optional cursor, the position an adapter assigns to it in an ordered source, yet
the framework throws that value away after the message is acknowledged. After this plan, a
processor whose adapter supplies cursors reports a `progress` member: the most recently
acknowledged cursor, and, where messages carry partition keys, one cursor per partition. An
inspection page can display those values and notice when they change; it never needs to
understand them. A processor whose adapter supplies no cursors shows no `progress` member at
all, so nothing is ever fabricated.

You can see it working by running a processor over a mock adapter whose envelopes carry
integer cursors, requesting `GET /metrics/<processorId>` from the metrics server, and
watching the `progress.latest` value advance as messages are acknowledged; the WebSocket
`update` frame for that processor carries the same member. Detailed recording uses one atomic bounded snapshot update per acknowledged message.
Its allocation and contention must be measured; the basic default bypasses the table entirely.

This plan delivers the progress item of the improvement request
`docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md`
(IR-3) and closes that request once its sibling plan
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`
(EP-49), which delivers the latency and oldest-in-flight items, is Complete. It is a child of
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`.


## Progress


- [ ] Milestone 1: `Cursor` JSON instances, `ProgressSnapshot`, `ProgressTable`, `recordAcknowledgedCursor`, the two hook sites, and `sampleMetrics` assembling the snapshot.
- [ ] Milestone 1: Paired performance capture and comparison at the shipped default level under `-N1` and `-N4`, plus the diagnostic detailed-level pair when the default is basic; every cell of the shipped default passes.
- [ ] Milestone 2: Concurrent cap tests (including capacity 0/1), integer precision boundaries, and finalization outcome tests.
- [ ] Milestone 2: Core unit tests in `shibuya-core/test/Shibuya/Core/MetricsSpec.hs` and runner tests in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` and the batch spec, each defect test seen failing first.
- [ ] Milestone 2: Metrics-package fixtures, golden update, round-trip, route, and WebSocket tests.
- [ ] Milestone 3: ADR extension, architecture documentation, Haddock, capability evidence, changelogs.
- [ ] Milestone 3: IR-3 closed with evidence after EP-49 is Complete; bundle validated.


## Surprises & Discoveries


2026-10-10 review: Use lossless browser cursor JSON, atomically enforce partition capacity, and populate cursor-bearing benchmark inputs. EP-49 is a hard dependency and basic remains the default.


## Decision Log


- Decision (2026-10-10): Use lossless browser cursor JSON, atomically enforce partition capacity, and populate cursor-bearing benchmark inputs. EP-49 is a hard dependency and basic remains the default.
  This revision supersedes conflicting 2026-09-30 design assumptions below.

- Decision: Record the most recently acknowledged cursor, not the highest one.
  Rationale: A cursor is opaque to the framework; `CursorText` values have no meaningful
  order, and even integer cursors from an unordered source need not be monotone. The request
  asks only that a client can display the value and compare it for change.
  Date: 2026-09-30

- Decision: Record a cursor only for `AckOk` and `AckDeadLetter` decisions after a successful
  finalization.
  Rationale: Those are the two decisions after which the adapter will not redeliver the
  message, which is what "acknowledged" means. An `AckRetry` message will come back, and an
  `AckHalt` stops the processor; recording either would report progress the source has not
  made.
  Date: 2026-09-30

- Decision: Bound the per-partition table by `DetailOptions.maxTrackedPartitions` and report
  `truncated: true` rather than growing without limit.
  Rationale: Partition keys are adapter-controlled and, for some sources, unbounded. A
  bounded table keeps the memory of a long-lived processor finite and keeps the miss path,
  the only allocating path, from being taken forever.
  Date: 2026-09-30

- Decision: Expose no Prometheus series for progress.
  Rationale: Prometheus samples are numbers over time; a cursor is opaque and may be text.
  Exporting only integer cursors would make the series appear and disappear by adapter, which
  is the fabricated-value behaviour ADR-0007 forbids. JSON and WebSocket carry the value.
  Date: 2026-09-30

- Decision: Reuse EP-49's `MetricsDetail` switch instead of adding a second switch.
  Rationale: One switch is simpler for host applications and for the read side, and the
  shipped default is decided by measurement in EP-49 and re-verified here.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


### What exists in the working tree today


Shibuya is a supervised queue-processing library. An *adapter* (`Shibuya.Adapter.Adapter` in
`shibuya-core/src/Shibuya/Adapter.hs`) produces a stream of *ingested* messages; each
ingested message wraps an *envelope* (`Shibuya.Core.Types.Envelope` in
`shibuya-core/src/Shibuya/Core/Types.hs`) with an acknowledgement handle. The envelope has
two optional members this plan is about. `cursor :: Maybe Cursor` is the adapter's position
for the message in its source, with `data Cursor = CursorInt !Int | CursorText !Text`; the
type has `Eq`, `Ord`, `Show`, `Generic`, and `NFData` instances and no JSON instances.
`partition :: Maybe Text` is an optional *partition key*, the identifier that groups
messages which must stay in order relative to one another (a Kafka partition, for example).
Neither value is read by the framework after the message is handed to the handler.

The framework's per-message path is `processOne` in
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`. It calls `beginProcessing` on the
processor's `MetricsHandle`, runs the handler, resolves the handler's `AckDecision`
(`AckOk`, `AckRetry`, `AckDeadLetter`, or `AckHalt`, from
`shibuya-core/src/Shibuya/Core/Ack.hs`), and calls `finalizeWithRetry` from
`shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs`, which invokes the adapter's
acknowledgement handle with bounded retry and returns `Right ()` on success or `Left` on
exhausted retry. It then calls `finishProcessing` and, for halts and finalization failures,
requests processor exit. The batch path is `processOneBatch` in
`shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs`; it runs a batch handler once
and then iterates its own retained list of messages, calling `finalizeWithRetry` for each and
collecting `(messageId, explicitlyNamed, decision, finalResult)` tuples in a `results` list.

Metrics live in `shibuya-core/src/Shibuya/Core/Metrics.hs`. A `MetricsHandle` is the
write-side handle of one processor: lock-free `AtomicCounter`s for received, processed,
failed, and in-flight (the *hot path*, the code executed once per message, where allocation
and contention are budgeted), and a `TVar ProcessorMetrics` for state and batch counters (the
*cold path*, executed rarely). `sampleMetrics :: MetricsHandle -> IO ProcessorMetrics`
combines both into the public `ProcessorMetrics` record, which today has `state`, `stats`,
`batch`, and `startedAt`, and derives `ToJSON` and `FromJSON` generically. The `Master`
(`shibuya-core/src/Shibuya/Internal/Runner/Master.hs`) keeps a registry of handles;
`getAllMetricsIO` and `getProcessorMetricsIO` sample them for the metrics server.

`shibuya-metrics` exposes that record. `shibuya-metrics/src/Shibuya/Metrics/JSON.hs` serves
`GET /metrics` and `GET /metrics/<processorId>`, and
`shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs` pushes an `update` frame whenever a
sampled `ProcessorMetrics` differs from the last one sent. Both encode the record with its
own `ToJSON` instance, so a new member on the record reaches every route and frame without
any change in that package. The package's tests are release-gated:
`shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs` builds hand-constructed fixtures in
`fixtureMetrics`, and `shibuya-metrics/test/golden/processor-metrics.json.golden` holds the
exact JSON those fixtures must encode to. A change to the encoder that is not reflected in
the golden file fails `cabal test shibuya-metrics`.

The repository's default policies are Fourmolu formatting through `nix fmt`, GHC2024 with
`NoFieldSelectors` and `OverloadedRecordDot` (fields are accessed as `handle.progress`),
named deriving strategies, and `effectful` for effects. `unordered-containers` (the
`Data.HashMap.Strict` hash map, a key-to-value structure with constant-time lookup by hashed
key) is already a dependency of `shibuya-core`; `containers` provides `Data.Map.Strict`.


### What EP-49 adds before this plan starts


This plan is implemented after
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`
and extends its artifacts. Read that plan's Outcomes & Retrospective and the code it landed
before starting, and expect to find exactly the following.

`Shibuya.Core.Metrics` exports `data MetricsDetail = MetricsBasic | MetricsDetailed
!DetailOptions` and `data DetailOptions = DetailOptions { maxTrackedPartitions :: !Int }` with
`defaultDetailOptions = DetailOptions 256`. The `maxTrackedPartitions` field is defined by
EP-49 but consumed for the first time by this plan. `MetricsHandle` has a `detail ::
MetricsDetail` field, and `newMetricsHandleWith :: MetricsDetail -> Int -> UTCTime -> IO
MetricsHandle` builds a handle for a given detail level and maximum concurrency;
`newMetricsHandle` still exists and means basic detail. `AppConfig` in
`shibuya-core/src/Shibuya/App.hs` has a `metricsDetail :: MetricsDetail` field whose default in
`defaultAppConfig` is MetricsBasic, exported from
`Shibuya.Core.Metrics` as `defaultMetricsDetail`; `runSupervisedWith` and
`runSupervisedBatchWith` take a `MetricsDetail` and thread it to `newMetricsHandleWith`,
while `runSupervised` and `runSupervisedBatch` keep their old types and delegate with
`defaultMetricsDetail`.

`ProcessorMetrics` has two new optional fields, `latency` and `oldestInFlight`, and its JSON
instances no longer derive `anyclass`: they use `genericToJSON` and `genericParseJSON` with
`defaultOptions {omitNothingFields = True}`, so a `Nothing` member is omitted from the object
rather than encoded as `null`. `emptyProcessorMetrics` sets every optional field to
`Nothing`. `processOne` calls `claimInFlightSlot` right after `beginProcessing` and
`releaseInFlightSlot` right after `finishProcessing`, each guarded by the handle's detail
level; `processOneBatch` does the same around its batch. EP-49 created
`shibuya-core/test/Shibuya/Core/MetricsSpec.hs`, registered it in
`shibuya-core/test/Main.hs` and the cabal `other-modules`, and extended
`fixtureMetrics` and the golden file with a processor carrying latency and oldest-in-flight
members. It also recorded the paired-harness procedure it used, which this plan repeats.

EP-49 also created an ADR titled "Account for in-flight detail and latency with bounded synchronized slots behind an opt-in detail level" in `docs/adr/`; its number is allocated when
EP-49 lands. This plan extends that ADR rather than creating a new one.


### Relevant decisions


`docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
is the contract this plan follows: published shapes are frozen and grow only additively;
JSON member names are camelCase (so the new members are `progress`, `latest`, `partitions`,
`truncated`); a `Nothing` member is omitted, never `null`; no value is ever fabricated; and
any per-message accounting is measured against the release budget before it is accepted, with
accounting that cannot meet the budget always-on placed behind the detail level. IR-3 asked
for snake_case members; ADR-0007 records the camelCase choice as a documented deviation, and
this plan restates it when closing the request.

`docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md` fixes the
performance budget: no more than 5% throughput loss, 5% allocation or live-memory growth,
and 10% latency growth, under paired alternating runs with confidence bounds, as encoded in
`docs/audits/lifecycle-release/performance-budgets.json`. An inconclusive result is not a
pass, and an agent never waives a failed gate.

`docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` contributes the rule
that a test asserting corrected or new behaviour must be observed failing against the code
without the change before it is trusted.

`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` defines the
halt-versus-failure distinction that decides which decisions count as acknowledged here. No
cross-repository ADR binds this plan.

Two terms of art used below: *monotone* means a sequence of values that never moves
backwards, which for integer cursors means never decreasing; the *cold path* of the table is
the code run the first time a partition key is seen, which is allowed to allocate.


## Plan of Work


### Milestone 1: Record acknowledged cursors and prove the cost


At the end of this milestone the framework remembers, for every detailed processor, the
cursor of the most recently acknowledged message and one cursor per partition key up to a
bound, `sampleMetrics` reports them, and a paired measurement shows the shipped default
level inside the release budget. Nothing is exposed differently yet beyond what the encoder
already does with a new record field.

Start in `shibuya-core/src/Shibuya/Core/Types.hs`. Give `Cursor` a lossless tagged JSON
encoding: `CursorInt n` becomes `{"kind":"integer","value":"<decimal n>"}` and
`CursorText t` becomes `{"kind":"text","value":t}`. The decoder accepts only these objects,
validates canonical signed decimal syntax and the platform Int range, and rejects unknown
kinds, fractional values, and out-of-range integers. Browsers cannot represent every 64-bit
Int as an exact JSON number; decimal text preserves identity above 2^53 and distinguishes an
integer cursor from a text cursor containing digits. These are new instances, not a change
to a shipped Cursor representation. Add boundary round trips for minBound, maxBound and
9007199254740993 on the supported 64-bit platform.


In `shibuya-core/src/Shibuya/Core/Metrics.hs` add the public snapshot type and the write-side
table. The snapshot is what a reader sees:

```haskell
-- | The most recently acknowledged cursors of one processor.
data ProgressSnapshot = ProgressSnapshot
  { -- | Cursor of the most recently acknowledged message, whatever its partition.
    latest :: !(Maybe Cursor),
    -- | Most recently acknowledged cursor per partition key, bounded by
    -- 'DetailOptions.maxTrackedPartitions'.
    partitions :: !(Map Text Cursor),
    -- | True once a partition key was seen after the table reached its bound;
    -- cursors for such keys are not tracked.
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)
```

Give it `ToJSON` and `FromJSON` through `genericToJSON` and `genericParseJSON` with the same
`omitNothingFields = True` options EP-49 introduced, so a snapshot with no `latest` yet omits
that member. Add `progress :: !(Maybe ProgressSnapshot)` to `ProcessorMetrics` after
`oldestInFlight`, set it to `Nothing` in `emptyProcessorMetrics`, and export
`ProgressSnapshot (..)`.

The table is private to the handle:

```haskell
data ProgressTable = ProgressTable
  { snapshot :: !(TVar ProgressSnapshot), maxPartitions :: !Int }
recordAcknowledgedCursor :: MetricsHandle -> Maybe Text -> Maybe Cursor -> IO ()
```

Allocate it only for detailed handles, with an empty snapshot. Recording a missing cursor
or a basic handle returns immediately without STM. Otherwise perform one strict STM update:
set latest to the original `Maybe Cursor`, replace an existing partition, insert a new key
only if the map size is below maxPartitions, and set truncated permanently when a new key
cannot fit. Membership, capacity and insertion must be one transaction; a separate count
IORef races and can exceed the bound. Zero permits latest-only tracking and marks truncation
on the first partitioned cursor; negative limits are rejected at construction. The snapshot
contains at most the configured number of keys under arbitrary concurrent acknowledgements.
Sample with one `readTVarIO`, exposing Nothing until a cursor has been recorded. This costs
an allocating Map update and synchronization in detailed mode; no steady-state zero-allocation
claim is made. A later optimization must preserve this reference behavior and pass the same
concurrency tests and measurements.

Latest means the last successful finalization recorded by this hook, not a globally highest
position or a committed checkpoint. Concurrent finalizers can publish in either order. Ordered
processing preserves observed source order per partition only when the adapter supplies
monotone cursors and does not reorder redeliveries; the framework never promises numeric
monotonicity for opaque values. Retried, halted, failed-finalization and cursorless messages
leave progress unchanged. Test all four, plus successful dead-letter finalization.


Now the two hook sites. In `processOne` in `Shibuya/Internal/Runner/Supervised.hs`, after the
`finalizeResult` case that records events and status and before the in-flight decrement,
add: when `finalizeResult` is `Right ()` and `result` is `Right AckOk` or `Right
(AckDeadLetter _)`, call `liftIO $ recordAcknowledgedCursor metricsHandle
ingested.envelope.partition ingested.envelope.cursor`. A handler exception is substituted
with `AckRetry`, so it never records. In `processOneBatch` in
`Shibuya/Internal/Runner/BatchProcessor.hs`, inside the `mapM` over `NE.toList batch` that
produces `results`, after `finalizeWithRetry` returns for a message and only when it returned
`Right ()` and the chosen decision `d` is `AckOk` or `AckDeadLetter _`, call the same hook
with that message's envelope; because the loop walks the retained list in batch order, a
partition's cursors are recorded in order.

Capture paired datasets using `scripts/audit/capture-performance-paired.ts`. The existing
`Bench/Lifecycle.hs:createMessages` sets partition but leaves `mkEnvelope.cursor = Nothing`,
so the existing eight workloads do not exercise cursor updates at all. Before comparison,
prepare one harness-only revision that sets a cursor fixture on these workloads, including
unpartitioned, repeated-key, hot-key and over-capacity inputs. Apply exactly that harness
source to the baseline (EP-49 complete) and candidate; record its tree/patch hash on both,
not a fabricated common SHA. Keep the original cursorless suite as the basic-path control.
Assert outside the timed region that detailed candidate snapshots actually contain expected
cursors and that the high-cardinality table reaches its cap with truncated true.

The default remains `defaultMetricsDetail = MetricsBasic` in both the App and direct runners.
Capture at least ten alternating pairs per scenario under -N1 and -N4; twenty for inconclusive
cells. Default comparisons must pass the canonical limits. For detailed diagnostic builds,
flip `defaultMetricsDetail` in both production trees, not just `defaultAppConfig` (most harness
paths call `runSupervised` directly); record exact patch hashes and verify detailed latency
and progress are present. Report detailed overhead against the EP-49 detailed baseline and
against the pre-initiative baseline in the final integration gate. Do not weaken progress
semantics by restricting recording to ordered processors or dropping partitions to make a
benchmark pass. Optimize or retain the explicit opt-in cost.

Use a focused copy of the canonical budget file with only requiredScenarios narrowed to
the captured eight scenarios; the full canonical file rejects missing scenarios. Preserve all
limits, exclusions, confidence parameters and minimumPairs. Hash normalized external package
identities from each solver plan, not raw plan.json files containing worktree paths. Store
raw datasets, the comparator reports and source identities under
`docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/`.


Acceptance for this milestone: `cabal build all` succeeds, the existing core and metrics
suites pass, and the comparator prints `pass` for every cell of the shipped default under
both capability counts.


### Milestone 2: Expose progress and test every promise


At the end of this milestone every behaviour above is pinned by a test that was seen failing
first, and the metrics package's golden fixture carries the new member deliberately.

Core unit tests go in `shibuya-core/test/Shibuya/Core/MetricsSpec.hs`, the module EP-49
created. Add a `describe "acknowledged cursor progress"` group: a basic handle from
`newMetricsHandle` ignores `recordAcknowledgedCursor` and samples `progress = Nothing`; a
detailed handle with no recorded cursor samples `Nothing`; recording `Just (CursorInt 7)`
with no partition samples `latest = Just (CursorInt 7)` and an empty `partitions` map;
recording under keys `"a"` then `"b"` samples both, and a later record under `"a"` replaces
only that entry; with `DetailOptions 2`, recording under a third key sets `truncated = True`,
leaves the map at two entries, and still advances `latest`; recording `Nothing` for the
cursor changes nothing. Use barriers to race many unique keys against capacity 1 and 2,
assert the map never exceeds its bound and truncation is sticky, and test capacity 0 plus
negative-limit rejection. Verify tagged Cursor JSON at Int boundaries and above 2^53. To see these fail first, write them against a tree that has the type
but not the hook body (or comment the body out in an isolated worktree), run `cabal test
shibuya-core --test-show-details=direct`, and record the failing example names in Surprises
& Discoveries before committing tests and code together.

Runner tests go in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`, which already
builds processors over `Shibuya.Adapter.Mock.listAdapter` and `runWithMetrics`; for the
detailed level use `runSupervisedWith (MetricsDetailed defaultDetailOptions)` with a `Master`
the way EP-49's tests do. Add five cases. First, an adapter whose envelopes have `cursor = Nothing` yields
`progress = Nothing` after all messages are acknowledged. Second, envelopes with
`CursorInt 1 .. CursorInt 5` on a serial processor yield `latest = Just (CursorInt 5)` at the
end, and, sampling after each acknowledgement, a `latest` that changes at every step; gate
each step with an `MVar` or `TVar` barrier released by a tracking acknowledgement handle
(`Shibuya.Adapter.Mock.trackedListAdapter` records every finalization), never with
`threadDelay`. Third, a `PartitionedInOrder` processor with `Async 4` over two partition keys
whose cursors increase within each partition yields, at every sampled step, per-partition
values that never decrease, and final values equal to each partition's last cursor. Fourth, a
handler returning `AckRetry (RetryDelay 0)` for one message leaves `latest` at the previous
cursor. Fifth, in `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs`, a batch of three
messages with cursors and two partition keys, acknowledged with `ackAllOk`, records the last
cursor of each partition and `latest` as the batch's last message.

Metrics-package tests. In `shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs`, add an additional
fixture processor, `ProcessorId "progressing"`, to `fixtureMetrics`, in the `Processing` state
with `progress = Just (ProgressSnapshot (Just (CursorInt 4210)) (Map.fromList [("p-0",
CursorInt 4210), ("p-1", CursorText "0198f2f3")]) False)`, and leave every other fixture's
`progress` at `Nothing`. Update `shibuya-metrics/test/golden/processor-metrics.json.golden`
so the new processor's object carries `"progress":{"latest":{"kind":"integer","value":"4210"},"partitions":{"p-0":{"kind":"integer","value":"4210"},"p-1":{"kind":"text","value":"0198f2f3"}},"truncated":false}`
and no other object gains a `progress` member; run the golden test, watch it fail on the old
file, then replace the file and record the diff in the Decision Log as deliberate. In
`shibuya-metrics/test/Shibuya/Metrics/TypesSpec.hs` add round trips for `CursorInt`,
`CursorText`, a snapshot with `latest = Nothing`, and a snapshot with `truncated = True`. In
`shibuya-metrics/test/Shibuya/Metrics/ServerSpec.hs` register one detailed handle with a
recorded cursor and one without, and assert that `GET /metrics/progressing` decodes to an
object containing `progress` while `GET /metrics/idle` decodes to one without that key. In
`shibuya-metrics/test/Shibuya/Metrics/WebSocketSpec.hs`, register a detailed handle, connect,
consume the snapshot, record a cursor, and assert the next `update` frame's metrics carry
the decoded `progress.latest = Just (CursorInt 1)`; the push loop compares whole records, so the recorded
cursor is itself the change that triggers the frame.

Acceptance: `cabal test shibuya-core` and `cabal test shibuya-metrics
--test-show-details=direct` both exit zero with the new example names visible, and the golden
diff shows exactly the one new object.


### Milestone 3: Record the decision, document the surface, and close IR-3


Extend the ADR EP-49 created, "Account for in-flight detail and latency with bounded synchronized slots behind an opt-in detail level", with a section on the bounded partition table: the
atomic bounded snapshot design, the measured atomic snapshot update,
the bound and the `truncated` flag, the last-writer-wins meaning of "most recently
acknowledged", and the decision to publish no Prometheus series. Advance its `Date:` line to
the day of the extension and add one sentence under Evidence pointing at this plan. Do not
renumber or rename it.

Add a "Progress" subsection to `docs/architecture/METRICS.md` after the batch statistics,
showing the `ProgressSnapshot` type, the JSON shape, when the member is present, the
monotonicity statement (per-partition values follow source order under `PartitionedInOrder` and are monotone only if the adapter and redelivery order are;
under `Async` or `Ahead` the unpartitioned `latest` may move backwards), and the detail-level
requirement. Update the Haddock of `Shibuya.Core.Metrics` for the new exports and the module
header of `shibuya-metrics/src/Shibuya/Metrics.hs`, which lists what the JSON routes and
frames carry, with one line for `progress`. Add to `docs/user/getting-started.md` (the user guide; `docs/USAGE_GUIDE.md` is only an
index) a short paragraph
under the metrics section stating that adapters which set `Envelope.cursor` get progress
reporting when `metricsDetail` is detailed.

Update the capability records. In `docs/capabilities/processor-introspection.md` (CAP-9) add
an evidence entry for the new runner tests, and in `docs/capabilities/metrics-endpoints.md`
(CAP-10) add evidence for the route and WebSocket tests and mention `progress` among the
processor members. Append entries with `okf log add docs/capabilities --kind Update -m
"..."` and validate the bundle with its profile as the existing records do.

Add changelog lines under an `Unreleased` heading in `CHANGELOG.md`,
`shibuya-core/CHANGELOG.md`, and `shibuya-metrics/CHANGELOG.md`: breaking for `shibuya-core`,
because `ProcessorMetrics` gains a field that direct record construction must supply; additive
for the `Cursor` JSON instances, `ProgressSnapshot`, and the `progress` member on the wire;
and, if Milestone 1 flipped the default detail level, a line saying so. Do not choose a
version.

Then close IR-3, only after EP-49 is Complete in the MasterPlan registry (this plan closes
the whole request, and the latency and oldest-in-flight items, including the identity of the
oldest in-flight message, were delivered there). In
`docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md`
set `status: completed`, add `completedAt` as the UTC time the last acceptance test passed,
add a `resolution` line naming EP-49, this plan, and the camelCase deviation recorded by
ADR-0007, and advance `timestamp` to the same instant. Rewrite its `## Status` section to
say the request is complete and where each acceptance item is proven. Append a log entry and
validate the bundle. The pre-existing advisories that every request lacks a `reviews` member
are expected and are not introduced by this change.


## Concrete Steps


All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, inside the Nix development shell.

Build and test after each edit:

```bash
cabal build all
cabal test shibuya-core --test-show-details=failures
cabal test shibuya-metrics --test-show-details=direct
nix fmt
```

A passing metrics run ends with a line such as `Finished in 3.2 seconds`, a nonzero example
count, and `0 failures`; a failing golden test prints the differing JSON.

To see a defect test fail first, use an isolated worktree, never the working tree:

```bash
git worktree add --detach /tmp/shibuya-ep50-red HEAD
# apply only the new test files in /tmp/shibuya-ep50-red, then:
cabal --project-dir=/tmp/shibuya-ep50-red test shibuya-core --test-show-details=direct
git worktree remove --force /tmp/shibuya-ep50-red
```

Performance capture. Build both executables with identical harness source; the baseline
worktree is at the EP-49 landing commit, the candidate is this tree:

```bash
git worktree add --detach /tmp/shibuya-ep50-baseline <ep49-landing-sha>
cabal --project-dir=/tmp/shibuya-ep50-baseline build shibuya-core-bench:lifecycle-load -O2
cabal build shibuya-core-bench:lifecycle-load -O2
mkdir -p docs/audits/lifecycle-release/artifacts/ep50-cursor-progress
jq '.requiredScenarios = ["serial-small-inbox","serial-full-inbox","ahead-uniform-keys","async-hot-key","async-high-cardinality","batch-size","retry-path","dead-letter-path"]' \
  docs/audits/lifecycle-release/performance-budgets.json \
  > docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/focused-budgets.json
BASE=$(cabal --project-dir=/tmp/shibuya-ep50-baseline list-bin shibuya-core-bench:lifecycle-load)
CAND=$(cabal list-bin shibuya-core-bench:lifecycle-load)
for RTS in -N1 -N4; do
  bun scripts/audit/capture-performance-paired.ts \
    --baseline-executable "$BASE" --candidate-executable "$CAND" \
    --baseline-output docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/baseline${RTS}.json \
    --candidate-output docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/candidate${RTS}.json \
    --baseline-label ep49-landed --candidate-label ep50-default \
    --baseline-production-sha <ep49-landing-sha> --candidate-production-sha "$(git rev-parse HEAD)" \
    --harness-sha "$(git rev-parse HEAD:shibuya-core-bench)" \
    --solver-plan-hash <normalized-external-solver-hash> \
    --machine-id "$(hostname)" --platform "$(uname -sm)" --compiler "$(ghc --numeric-version)" \
    --optimization O2 --rts "$RTS" --capabilities "${RTS#-N}" --iterations 10 \
    --scenarios serial-small-inbox,serial-full-inbox,ahead-uniform-keys,async-hot-key,async-high-cardinality,batch-size,retry-path,dead-letter-path
  bun scripts/audit/compare-performance.ts \
    --baseline docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/baseline${RTS}.json \
    --candidate docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/candidate${RTS}.json \
    --budgets docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/focused-budgets.json \
    --output docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/verdict${RTS}.json
done
```

The capture script prints `captured 10 paired -N1 samples for <scenario>` per scenario and
then `wrote 80 baseline and 80 candidate samples`; the comparator prints one line per
scenario and metric ending in `pass`, `fail`, or `inconclusive`, and exits nonzero on any
`fail`. Verify the harness SHA and solver-plan hash are identical between the two builds
before trusting a verdict. Repeat with identical cursor-bearing harness sources and the diagnostic detailed-default build when the shipped
default is basic, labelling the outputs `diagnostic-detailed`.

Records and bundles:

```bash
okf log add docs/capabilities --kind Update -m "CAP-9 and CAP-10 cite the acknowledged cursor progress tests."
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf log add docs/improvement-requests --kind Update -m "IR-3 completed: latency and oldest in-flight by EP-49, progress by EP-50; camelCase members per ADR-0007."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Commit in small conventional commits with these trailers on every commit:

```text
MasterPlan: docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md
ExecPlan: docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md
Intention: intention_01m3ta8zgtebmaz00g0snjzy5a
```


## Validation and Acceptance


Run a processor over a mock adapter whose envelopes carry cursors under a detailed
configuration, start the metrics server, and request the processor:

```bash
curl -s http://127.0.0.1:9090/metrics/orders | jq .progress
```

Expected, after several acknowledgements on two partitions:

```json
{
  "latest": {"kind":"integer","value":"4210"},
  "partitions": { "p-0": {"kind":"integer","value":"4210"}, "p-1": {"kind":"integer","value":"4207"} },
  "truncated": false
}
```

Requesting a processor whose adapter sets no cursor returns an object with no `progress`
key, and a basic-level application returns none for any processor. A WebSocket client that
sends `{"type":"subscribe_all"}` receives `update` frames whose `metrics.progress.latest`
changes as messages are acknowledged. For the test fixture with monotone cursors and no reordering, a processor under
`PartitionedInOrder` preserves per-partition order; this is not a universal cursor guarantee. Retried
messages do not advance any cursor. The Prometheus route is byte-for-byte unchanged by this
plan.

`cabal test shibuya-core` passes all three suites with the new MetricsSpec, SupervisedSpec,
and BatchProcessorSpec examples; `cabal test shibuya-metrics` passes with the updated golden
file, round trips, route, and WebSocket examples. Each defect test is recorded as having
failed first. The comparator verdict for the shipped default level is `pass` in every cell
under `-N1` and `-N4`, with datasets and verdicts committed under
`docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/`. Both capability bundles and
the improvement-request bundle validate, and IR-3's frontmatter reads `status: completed`.


## Idempotence and Recovery


Every build, test, and validation command is safe to repeat. The performance capture writes
new dataset files each run; keep only the run whose harness SHA and solver hash match and
delete superseded files before committing. Worktrees created for red tests or baselines are
removed with `git worktree remove --force`; if a removal fails because of a stale lock,
`git worktree prune` clears it. If a golden update was applied prematurely, restore the file
with `git checkout -- shibuya-metrics/test/golden/processor-metrics.json.golden` and redo the
red-then-green sequence. If the default detail level is flipped and later found unnecessary,
revert only that commit; the recording code does not depend on the default. Never edit
IR-3's `requestId` or the request's origin; closing edits only `status`, `completedAt`,
`resolution`, `timestamp`, and the Status section. Do not touch the pinned
`docs/improvement-requests/profile.dhall`.


## Interfaces and Dependencies


This plan uses `aeson` (already a `shibuya-core` dependency) for the new instances,
`containers` for Data.Map.Strict and `stm` for the atomic snapshot; it adds no dependency. Verify no bound needs widening with `cabal
build all` before touching any cabal file.

Interfaces that exist at the end of Milestone 1, all in `shibuya-core`:

```haskell
-- Shibuya.Core.Types
instance ToJSON Cursor    -- tagged kind and lossless textual value
instance FromJSON Cursor  -- validated tagged object

-- Shibuya.Core.Metrics
data ProgressSnapshot = ProgressSnapshot
  { latest :: !(Maybe Cursor), partitions :: !(Map Text Cursor), truncated :: !Bool }
instance ToJSON ProgressSnapshot   -- omitNothingFields = True
instance FromJSON ProgressSnapshot

data ProgressTable = ProgressTable
  { snapshot :: !(TVar ProgressSnapshot), maxPartitions :: !Int }


-- new field on MetricsHandle:      progress :: !(Maybe ProgressTable)
-- new field on ProcessorMetrics:   progress :: !(Maybe ProgressSnapshot)

recordAcknowledgedCursor :: MetricsHandle -> Maybe Text -> Maybe Cursor -> IO ()
```

`newMetricsHandleWith`, `MetricsDetail`, `DetailOptions`, and the `omitNothingFields`
encoder options are owned by EP-49 and only consumed here; `sampleMetrics` gains the snapshot
assembly. The hook is called from `Shibuya.Internal.Runner.Supervised.processOne` and
`Shibuya.Internal.Runner.BatchProcessor.processOneBatch`, whose signatures do not change.

Dependencies: a hard dependency on
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`,
which must land first because it owns the detail switch, the encoder options, the hook
sites' surrounding guards, the `MetricsSpec` module, and the fixture layout this plan
extends, and because IR-3 closes only when both are Complete. The sibling
`docs/plans/51-implement-source-level-processor-pause-and-resume.md` also edits
`Shibuya.Core.Metrics` (a new `ProcessorState` constructor and sampling rule); the edits are
disjoint, so whichever lands second rebases onto the first. The metrics package needs no
code change from this plan beyond tests, fixtures, and documentation.


Revision note (2026-10-10): API and performance review applied. Use lossless browser cursor JSON, atomically enforce partition capacity, and populate cursor-bearing benchmark inputs. EP-49 is a hard dependency and basic remains the default. Implementation and performance measurements remain pending.
