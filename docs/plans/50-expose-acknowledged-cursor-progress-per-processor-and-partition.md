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
`update` frame for that processor carries the same member. The recording costs one hash-map
lookup and one pointer write per acknowledged message and allocates nothing in steady state,
and this plan proves that with the repository's paired performance harness before the change
is accepted.

This plan delivers the progress item of the improvement request
`docs/improvement-requests/expose-processor-progress-latency-and-in-flight-detail-for-inspection-uis.md`
(IR-3) and closes that request once its sibling plan
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`
(EP-49), which delivers the latency and oldest-in-flight items, is Complete. It is a child of
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`.


## Progress


- [ ] Milestone 1: `Cursor` JSON instances, `ProgressSnapshot`, `ProgressTable`, `recordAcknowledgedCursor`, the two hook sites, and `sampleMetrics` assembling the snapshot.
- [ ] Milestone 1: Paired performance capture and comparison at the shipped default level under `-N1` and `-N4`, plus the diagnostic detailed-level pair when the default is basic; every cell of the shipped default passes.
- [ ] Milestone 2: Core unit tests in `shibuya-core/test/Shibuya/Core/MetricsSpec.hs` and runner tests in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` and the batch spec, each defect test seen failing first.
- [ ] Milestone 2: Metrics-package fixtures, golden update, round-trip, route, and WebSocket tests.
- [ ] Milestone 3: ADR extension, architecture documentation, Haddock, capability evidence, changelogs.
- [ ] Milestone 3: IR-3 closed with evidence after EP-49 is Complete; bundle validated.


## Surprises & Discoveries


(None yet.)


## Decision Log


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
`defaultAppConfig` is whichever level EP-49's measurement supported, exported from
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

EP-49 also created an ADR titled "Account for in-flight detail and latency off the
allocation path behind a measured detail level" in `docs/adr/`; its number is allocated when
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

Start in `shibuya-core/src/Shibuya/Core/Types.hs`. Add `ToJSON` and `FromJSON` instances for
`Cursor` written by hand: `toJSON (CursorInt n)` is `toJSON n` (a JSON number) and `toJSON
(CursorText t)` is `toJSON t` (a JSON string); `parseJSON` accepts a number as `CursorInt`
and a string as `CursorText` and rejects anything else with a message naming the expected
shapes. The module already imports nothing from Aeson, so add the import; `aeson` is already
a dependency. Document on the type that the JSON value is opaque to clients.

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

The table is private to the handle and holds mutable cells:

```haskell
data ProgressTable = ProgressTable
  { latest :: !(IORef (Maybe Cursor)),
    partitions :: !(IORef (HashMap Text (IORef (Maybe Cursor)))),
    partitionCount :: !(IORef Int),
    truncated :: !(IORef Bool),
    maxPartitions :: !Int
  }
```

Add `progress :: !(Maybe ProgressTable)` to `MetricsHandle`. In `newMetricsHandleWith`,
construct a table when the detail is `MetricsDetailed options`, taking `maxPartitions` from
`options.maxTrackedPartitions`, and store `Nothing` for `MetricsBasic`; `newMetricsHandle`
therefore always has `Nothing`. Export `ProgressTable` abstractly if EP-49's pattern exports
its own table types, otherwise keep it internal; the metrics package never touches it.

Write the hook:

```haskell
-- | Remember the cursor of a message the adapter will not redeliver. A no-op
-- for a basic handle or a message without a cursor. In steady state this is
-- one hash-map lookup and one pointer write with no allocation; only the
-- first sight of a partition key takes the allocating cold path.
recordAcknowledgedCursor :: MetricsHandle -> Maybe Text -> Maybe Cursor -> IO ()
recordAcknowledgedCursor handle partitionKey cursor =
  case (handle.progress, cursor) of
    (Just table, Just value) -> record table partitionKey value
    _ -> pure ()
{-# INLINE recordAcknowledgedCursor #-}
```

The `record` helper writes `Just value` into `table.latest` with `writeIORef` (the `Maybe
Cursor` value is the envelope's own, already allocated, so this is a pointer write). When
`partitionKey` is `Just key`, it reads the hash map with `readIORef`, looks the key up, and on
a hit writes the slot with `writeIORef`. On a miss it reads `partitionCount`; if the count is
below `maxPartitions` it allocates a new `IORef (Just value)`, inserts it with
`atomicModifyIORef'` on the map cell (re-checking that a concurrent writer has not inserted
the same key, in which case it writes that slot instead and does not increment), and
increments the count; otherwise it writes `True` into `truncated` and records nothing for that
key. Concurrent writers to one slot are last-writer-wins, which is the documented meaning of
"most recently acknowledged". Do not use STM on this path.

In `sampleMetrics`, when the handle has a table, read `latest`, traverse the hash map reading
every slot, convert the result to a `Map Text Cursor` (dropping slots still `Nothing`, which
cannot occur after creation but keeps the code total), read `truncated`, and set `progress =
Just snapshot` only if `latest` is `Just` or the map is non-empty; otherwise leave
`Nothing`, so a detailed processor that has acknowledged no cursor-bearing message shows no
member. This traversal is the read-side cost the request explicitly accepts.

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

Build and run the existing suites so that nothing regressed, then measure. The harness is
`cabal run shibuya-core-bench:lifecycle-load`, driven by
`scripts/audit/capture-performance-paired.ts`, which runs two executables in alternating
order and writes two datasets that `scripts/audit/compare-performance.ts` judges against
`docs/audits/lifecycle-release/performance-budgets.json`. The two executables must be built
from the same harness source: build the baseline from a clean worktree at the commit where
EP-49 landed and the candidate from your tree with this milestone applied, both with `-O2`
and the same solver plan, and pass the same harness SHA. The scenarios that exercise this
change are `serial-small-inbox`, `serial-full-inbox`, `ahead-uniform-keys`, `async-hot-key`,
`async-high-cardinality` (its distinct partition keys exercise the table and its bound),
`batch-size`, `retry-path` (which must show that retries record nothing), and
`dead-letter-path`. Run at least ten alternating pairs under `-N1` and again under `-N4`.

Apply this rule. The shipped default level, the value of `metricsDetail` in
`defaultAppConfig`, must pass every cell. If EP-49 shipped `MetricsBasic` as the default,
the default-level comparison exercises only the `Nothing` branch of the hook and must show
no regression; then run one additional diagnostic pair with both executables' default
flipped to `MetricsDetailed defaultDetailOptions` (change `defaultAppConfig` in both
worktrees for the diagnostic build only, and do not commit that change) and record its
numbers in Surprises & Discoveries without gating on them. If EP-49 shipped
`MetricsDetailed` as the default and any cell fails or is inconclusive after twenty pairs,
first reduce the cost, for example by computing the key's hash once and looking up by hash,
by narrowing the table to `PartitionedInOrder` processors, or by storing the latest cursor
only; if it still fails, change `defaultAppConfig` to `MetricsBasic`, record the flip in the
Decision Log, the three changelogs, and the ADR extension, and re-run the default-level
comparison so that the shipped default passes. Store the datasets, the verdict JSON, and the
exact commands under `docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/`.

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
cursor changes nothing. To see these fail first, write them against a tree that has the type
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

Metrics-package tests. In `shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs`, add a fifth
fixture processor, `ProcessorId "progressing"`, to `fixtureMetrics`, in the `Processing` state
with `progress = Just (ProgressSnapshot (Just (CursorInt 4210)) (Map.fromList [("p-0",
CursorInt 4210), ("p-1", CursorText "0198f2f3")]) False)`, and leave every other fixture's
`progress` at `Nothing`. Update `shibuya-metrics/test/golden/processor-metrics.json.golden`
so the new processor's object carries `"progress":{"latest":4210,"partitions":{"p-0":4210,"p-1":"0198f2f3"},"truncated":false}`
and no other object gains a `progress` member; run the golden test, watch it fail on the old
file, then replace the file and record the diff in the Decision Log as deliberate. In
`shibuya-metrics/test/Shibuya/Metrics/TypesSpec.hs` add round trips for `CursorInt`,
`CursorText`, a snapshot with `latest = Nothing`, and a snapshot with `truncated = True`. In
`shibuya-metrics/test/Shibuya/Metrics/ServerSpec.hs` register one detailed handle with a
recorded cursor and one without, and assert that `GET /metrics/progressing` decodes to an
object containing `progress` while `GET /metrics/idle` decodes to one without that key. In
`shibuya-metrics/test/Shibuya/Metrics/WebSocketSpec.hs`, register a detailed handle, connect,
consume the snapshot, record a cursor, and assert the next `update` frame's metrics carry
`progress.latest = Just (CursorInt 1)`; the push loop compares whole records, so the recorded
cursor is itself the change that triggers the frame.

Acceptance: `cabal test shibuya-core` and `cabal test shibuya-metrics
--test-show-details=direct` both exit zero with the new example names visible, and the golden
diff shows exactly the one new object.


### Milestone 3: Record the decision, document the surface, and close IR-3


Extend the ADR EP-49 created, "Account for in-flight detail and latency off the allocation
path behind a measured detail level", with a section on the bounded partition table: the
hash-map-of-cells design, the one-lookup-one-write steady state, the allocating cold path,
the bound and the `truncated` flag, the last-writer-wins meaning of "most recently
acknowledged", and the decision to publish no Prometheus series. Advance its `Date:` line to
the day of the extension and add one sentence under Evidence pointing at this plan. Do not
renumber or rename it.

Add a "Progress" subsection to `docs/architecture/METRICS.md` after the batch statistics,
showing the `ProgressSnapshot` type, the JSON shape, when the member is present, the
monotonicity statement (per-partition values are monotone only under `PartitionedInOrder`;
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
    --solver-plan-hash "$(sha256sum dist-newstyle/cache/plan.json | cut -d' ' -f1)" \
    --machine-id "$(hostname)" --platform "$(uname -sm)" --compiler "$(ghc --numeric-version)" \
    --optimization O2 --rts "$RTS" --capabilities "${RTS#-N}" --iterations 10 \
    --scenarios serial-small-inbox,serial-full-inbox,ahead-uniform-keys,async-hot-key,async-high-cardinality,batch-size,retry-path,dead-letter-path
  bun scripts/audit/compare-performance.ts \
    --baseline docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/baseline${RTS}.json \
    --candidate docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/candidate${RTS}.json \
    --budgets docs/audits/lifecycle-release/performance-budgets.json \
    --output docs/audits/lifecycle-release/artifacts/ep50-cursor-progress/verdict${RTS}.json
done
```

The capture script prints `captured 10 paired -N1 samples for <scenario>` per scenario and
then `wrote 80 baseline and 80 candidate samples`; the comparator prints one line per
scenario and metric ending in `pass`, `fail`, or `inconclusive`, and exits nonzero on any
`fail`. Verify the harness SHA and solver-plan hash are identical between the two builds
before trusting a verdict. Repeat with the diagnostic detailed-default build when the shipped
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
  "latest": 4210,
  "partitions": { "p-0": 4210, "p-1": 4207 },
  "truncated": false
}
```

Requesting a processor whose adapter sets no cursor returns an object with no `progress`
key, and a basic-level application returns none for any processor. A WebSocket client that
sends `{"type":"subscribe_all"}` receives `update` frames whose `metrics.progress.latest`
changes as messages are acknowledged. A processor under `PartitionedInOrder` never shows a
per-partition value smaller than the previous sample's value for that partition. Retried
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
`unordered-containers` for `Data.HashMap.Strict`, `containers` for `Data.Map.Strict`, and
`base`'s `Data.IORef`; it adds no dependency. Verify no bound needs widening with `cabal
build all` before touching any cabal file.

Interfaces that exist at the end of Milestone 1, all in `shibuya-core`:

```haskell
-- Shibuya.Core.Types
instance ToJSON Cursor    -- CursorInt n -> number, CursorText t -> string
instance FromJSON Cursor  -- number -> CursorInt, string -> CursorText

-- Shibuya.Core.Metrics
data ProgressSnapshot = ProgressSnapshot
  { latest :: !(Maybe Cursor), partitions :: !(Map Text Cursor), truncated :: !Bool }
instance ToJSON ProgressSnapshot   -- omitNothingFields = True
instance FromJSON ProgressSnapshot

data ProgressTable = ProgressTable
  { latest :: !(IORef (Maybe Cursor)),
    partitions :: !(IORef (HashMap Text (IORef (Maybe Cursor)))),
    partitionCount :: !(IORef Int),
    truncated :: !(IORef Bool),
    maxPartitions :: !Int }

-- new field on MetricsHandle:      progress :: !(Maybe ProgressTable)
-- new field on ProcessorMetrics:   progress :: !(Maybe ProgressSnapshot)

recordAcknowledgedCursor :: MetricsHandle -> Maybe Text -> Maybe Cursor -> IO ()
```

`newMetricsHandleWith`, `MetricsDetail`, `DetailOptions`, and the `omitNothingFields`
encoder options are owned by EP-49 and only consumed here; `sampleMetrics` gains the snapshot
assembly. The hook is called from `Shibuya.Internal.Runner.Supervised.processOne` and
`Shibuya.Internal.Runner.BatchProcessor.processOneBatch`, whose signatures do not change.

Dependencies: a soft dependency on
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`,
which must land first because it owns the detail switch, the encoder options, the hook
sites' surrounding guards, the `MetricsSpec` module, and the fixture layout this plan
extends, and because IR-3 closes only when both are Complete. The sibling
`docs/plans/51-implement-source-level-processor-pause-and-resume.md` also edits
`Shibuya.Core.Metrics` (a new `ProcessorState` constructor and sampling rule); the edits are
disjoint, so whichever lands second rebases onto the first. The metrics package needs no
code change from this plan beyond tests, fixtures, and documentation.
