# Metrics and Observability

This document describes Shibuya's metrics and introspection capabilities.

## Metrics Types

### ProcessorId

```haskell
newtype ProcessorId = ProcessorId { unProcessorId :: Text }
```

Unique identifier for each processor. Used as key in MetricsMap.

### InFlightInfo

```haskell
data InFlightInfo = InFlightInfo
  { inFlight       :: !Int
  , maxConcurrency :: !Int
  }
```

Tracks the number of handlers currently executing and the configured concurrency limit.

### ProcessorState

```haskell
data ProcessorState
  = Idle
  | Processing !InFlightInfo !UTCTime !UTCTime
  | Failed !Text !UTCTime
  | Stopped
```

| State | Meaning |
|-------|---------|
| `Idle` | Waiting for next message |
| `Processing info burstStarted lastProgress` | Currently processing; exposes the sampled burst start and most recent sampled handler progress |
| `Failed msg time` | Last processing failed with error |
| `Stopped` | Processor has been stopped |

### StreamStats

```haskell
data StreamStats = StreamStats
  { received  :: !Int  -- Messages received from adapter
  , processed :: !Int  -- Messages successfully processed
  , failed    :: !Int  -- Messages that failed processing
  }
```

Counters for message processing:

| Counter | Incremented When |
|---------|-----------------|
| `received` | Ingester sends message to inbox |
| `processed` | Handler returns `AckOk` or `AckRetry` |
| `failed` | Handler returns `AckDeadLetter` or throws |

### BatchStats

```haskell
data BatchStats = BatchStats
  { batchesEmitted  :: !Int  -- batches handed to the batch handler
  , batchedMessages :: !Int  -- total messages across all emitted batches
  , partialFailures :: !Int  -- batches where the handler named >=1 failing message
  , sizeTriggered   :: !Int  -- batches emitted at batchSize
  , timeoutTriggered :: !Int -- batches emitted at batchTimeout
  , flushTriggered  :: !Int  -- batches emitted by a drain/shutdown flush
  }
```

Batch-processing counters, tracked alongside per-message `StreamStats`:

| Counter | Incremented When |
|---------|-----------------|
| `batchesEmitted` | A batch is emitted and handed to the batch handler |
| `batchedMessages` | Add `N` for every emitted batch of `N` messages |
| `partialFailures` | The handler returns normally and names ≥ 1 message with a failing decision (counted per batch, not per message) |
| `sizeTriggered` | A batch is emitted because it reached `batchSize` (`TriggerSize`) |
| `timeoutTriggered` | A batch is emitted because `batchTimeout` elapsed (`TriggerTimeout`) |
| `flushTriggered` | A batch is emitted by a drain/shutdown flush (`TriggerFlush`) |

For a non-batching processor these counters are all zero; for a batching
processor they summarize batch-level activity while `stats` continues to count
per-message outcomes (each message in a batch is finalized individually, so
`stats.processed`/`stats.failed` update exactly as for single-message
processing).

### ProcessorMetrics

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState
  , stats     :: !StreamStats
  , batch     :: !BatchStats
  , startedAt :: !UTCTime
  }
```

Combined metrics for a single processor.

Progress timing is sampled when metrics are read, rather than adding a clock read
to every handler start and finish. A changing completion, in-flight, or burst
generation counter advances `lastProgress`; readiness reports a processor stuck
only after a full `stuckThreshold` with no sampled change. One wedged handler is
not detectable while sibling handlers on the same processor continue to make
progress.

### MetricsMap

```haskell
type MetricsMap = Map ProcessorId ProcessorMetrics
```

Metrics for all processors, keyed by ID.

## Accessing Metrics

### From AppHandle

```haskell
getAppMetrics :: AppHandle es -> Eff es MetricsMap
```

Get metrics for all processors:

```haskell
appHandle <- runApp ...
metrics <- getAppMetrics appHandle
-- metrics :: Map ProcessorId ProcessorMetrics
```

### From SupervisedProcessor

```haskell
getMetrics        :: SupervisedProcessor -> Eff es ProcessorMetrics
getProcessorState :: SupervisedProcessor -> Eff es ProcessorState
isDone            :: SupervisedProcessor -> Eff es Bool
```

Get metrics for a single processor:

```haskell
sp <- runWithMetrics 100 (ProcessorId "test") adapter handler
metrics <- getMetrics sp
state <- getProcessorState sp
done <- isDone sp
```

### From Master

```haskell
getAllMetrics        :: (IOE :> es) => Master -> Eff es MetricsMap
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
```

Direct access via Master handle.

### IO Accessor Functions

For use outside of the `Eff` monad (e.g., from Prometheus metrics callbacks):

```haskell
getAllMetricsIO        :: Master -> IO MetricsMap
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
```

## Metrics Flow

```
┌─────────────────────────────────────────────────────────────┐
│                          Master                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              MetricsMap (TVar)                        │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │  │
│  │  │ proc-1      │  │ proc-2      │  │ proc-3      │   │  │
│  │  │ TVar        │  │ TVar        │  │ TVar        │   │  │
│  │  │ Metrics     │  │ Metrics     │  │ Metrics     │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘   │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │                    │                    │
    ┌────┴────┐          ┌────┴────┐          ┌────┴────┐
    │Processor│          │Processor│          │Processor│
    │   1     │          │   2     │          │   3     │
    └─────────┘          └─────────┘          └─────────┘
```

Each processor:
1. Creates its own `MetricsHandle`
2. Registers the handle with Master on startup
3. Updates hot per-message counters with fetch-and-add operations
4. Updates colder state, batch counters, and metadata in a `TVar ProcessorMetrics`
5. Samples the hot and cold state together when metrics are read
6. Unregisters from Master on shutdown

This design allows:
- O(1) metrics reads (no locking needed for reads)
- Processors update their own metrics independently
- Master provides aggregated view
- The per-message hot path avoids STM writes for simple counters

## Example: Monitoring Processing

```haskell
monitorLoop :: AppHandle es -> Eff es ()
monitorLoop appHandle = do
  metrics <- getAppMetrics appHandle
  forM_ (Map.toList metrics) $ \(procId, pm) -> do
    liftIO $ putStrLn $ unpack (unProcessorId procId)
      <> ": received=" <> show pm.stats.received
      <> ", processed=" <> show pm.stats.processed
      <> ", failed=" <> show pm.stats.failed
      <> ", state=" <> show pm.state

  liftIO $ threadDelay 1_000_000  -- 1 second
  monitorLoop appHandle
```

## Supervision Strategies

Shibuya defines its own `SupervisionStrategy` type that maps to NQE strategies internally:

```haskell
data SupervisionStrategy
  = IgnoreFailures     -- Other processors continue if one fails
  | StopAllOnFailure   -- All processors stop if any fails
```

| SupervisionStrategy | NQE Strategy | Behavior |
|---------------------|--------------|----------|
| `IgnoreFailures` | `IgnoreAll` | Keep running, ignore dead children |
| `StopAllOnFailure` | `IgnoreGraceful` | Stop all children on failure, but do not treat graceful exits as failures |

Recommended: `IgnoreFailures` for most queue processing (let individual processors fail without affecting others).

## WebSocket protocol and conformance

`/ws` starts with a snapshot of all live processors. Clients send `subscribe_all`,
`subscribe` with a `processors` array, `unsubscribe` with a `processors` array, or `ping`.
Subscribe-all clears exclusions; selective subscribe selects or extends a finite set;
unsubscribe removes selections or adds exclusions in all mode. Each subscription mutation
establishes a new snapshot boundary. Updates from the previous selection cannot follow that
snapshot. The default push interval is 100 ms, independently of receive traffic and writes.

Server frames are `snapshot` (`metrics`), `update` (`processor`, `metrics`), `terminal`
(`processor`, `status`, and the published failure context), `pong`, `goodbye`, and additive
`error` (`code`, `message`). Existing frame names, members and types remain unchanged.
An extension-tolerant consumer can ignore unknown tags; a decoder with a closed tag set must
add `error`. Adding `ServerError` also requires downstream exhaustive Haskell matches to change.

| Error code | Behavior |
| --- | --- |
| `invalid_message` | Invalid JSON, missing members or unknown client tag; receive continues. `message` contains the decoder reason and is not a stable parsing API. |
| `subscription_limit_exceeded` | Error before policy close 1008, subject to available required-frame capacity and the send deadline. |
| `queue_overflow` | Deltas were dropped; the very next application frame is a complete replacement snapshot. Replace the client's current map. |

Every connection has one application writer and one bounded outbound queue. Defaults are
`wsMaxQueuedFrames = 64` (minimum 2), `wsMaxQueuedBytes = 1048576` (positive), and
`wsSendTimeoutUs = 5000000` (positive). The built-in runner validates these; hosts mounting
`combinedApp` validate configuration themselves. Counts include snapshots, terminal events,
errors, recovery snapshots and goodbye. Strict encoded payloads are forced before admission.
The writer can hold one popped frame outside the queue. The budgets bound retained queue
payloads, not the whole process heap, decoded input, metrics maps, or transient encodings used to build an admission batch.
Raise the byte budget explicitly if the registry's initial snapshot is larger than 1 MiB.

Updates and pongs are expendable and evicted oldest-first. Losing updates marks recovery
pending and suppresses ordinary deltas until the next producer sample admits terminal removals
and an indivisible error/snapshot pair. Earlier required frames retain their order. Required
saturation or an oversized required payload requests close 1013 instead of increasing either
budget. Invalid-message floods are subject to the same limits. One close control signal lives
outside the queue, rather than an unbounded list of close commands.

Shutdown stops admission, discards expendable updates as needed, and queues goodbye after
admitted required frames. Each write and the entire orderly flush have one finite deadline.
Responsive shutdown peers receive goodbye before close 1000; stalled peers may time out without
receiving it. Policy and capacity closes do not promise goodbye. Local connection slots are
released even after timeout or setup failure. An admitted terminal event appears once on a live
connection, but neither terminal nor goodbye has a disconnected-peer delivery guarantee.
Reconnect and fetch current state from a snapshot or `GET /metrics`; this feed is not a replay log.

The shared convention is owned by `mori://shinzui/keiro-ui`,
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending), with its durable
record at `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`. The mapping below keeps each deliberate
deviation explicit; [ADR-0007](../adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md)
freezes Shibuya's dialect and [ADR-0008](../adr/0008-deliver-websocket-frames-through-one-bounded-outbound-queue-per-connection.md)
defines bounded delivery.

| Convention element | Result | Shibuya contract and evidence |
| --- | --- | --- |
| Optional sister package, HTTP/JSON and embeddable application | Met | Web dependencies stay in `shibuya-metrics`; `combinedApp` and convenience runners are exported. |
| Type-tagged JSON frames | Met | Exact objects and round trips in `TypesSpec`. |
| Explicit subscribe/unsubscribe and snapshot then deltas | Met | Real loopback and controlled generation-boundary tests in `WebSocketSpec`. |
| Connection initially watches nothing | Documented deviation | The published dialect initially watches all and sends a snapshot immediately. |
| Client ping/pong and server ping | Met | Application ping/pong plus the existing 30-second protocol ping thread. Expendable pongs may be lost under pressure. |
| In-band per-connection errors | Additively closed | Stable `invalid_message`, `subscription_limit_exceeded`, and `queue_overflow` codes. |
| Bounded delivery and drop-oldest overflow signaling | Additively closed | Strict frame/byte bounds, independent producer, sole writer and adjacent error/snapshot recovery. `OutboundQueueSpec` exhaustively checks transition traces. |
| Goodbye before responsive server shutdown | Met | Ordered required goodbye followed by close 1000, verified on loopback. |
| Goodbye before every server-initiated close | Documented deviation | Policy/capacity refusal and stalled sends may close without goodbye; required-frame limits and finite deadlines win over undeliverable promises. |
| Replay cursor `from_position` | Documented deviation | Metrics are current state without replayable positions; recovery reads a fresh snapshot. |
| Snake-case new JSON member names | Documented deviation | Shibuya keeps camelCase member names under ADR-0007; tags, enumerated values and error codes use snake_case. |
| Nested error envelope | Documented deviation | Published HTTP errors keep `error` text plus additive `code`; WebSocket errors use a flat typed frame. |
| Pagination | Not applicable | Current metrics are a single map, not a position-based event page. |
| Push is a hint, authoritative read backs it | Met | `GET /metrics` and snapshots supply current state after loss; no NOTIFY or replay assumption. |
| Configurable CORS and upgrade Origin | Met | Explicit allowed origins, disabled by default, implemented in EP-47 and covered by `CorsSpec` and loopback upgrade tests. |
| Authentication and authorization posture | Documented gap, as expected | No built-in authentication. Use a trusted network or authenticating proxy. Origin validation is not authentication. Future control remains separately gated. |
| Frozen published shapes and domain vocabulary | Met | Existing JSON/Prometheus goldens and frame contracts remain unchanged; errors and snapshot boundaries are additive. |

## Latency and in-flight detail

`AppConfig.metricsDetail` defaults to `MetricsBasic`, which retains the existing counter
and sampled-progress path without per-attempt clocks or slot cleanup. Opt in with
`MetricsDetailed defaultDetailOptions`. Each processor allocates one synchronized slot per
configured concurrent handler (or concurrent batch). The slot publishes the message identity
and monotonic start together, and retains its own histogram. Slot locks cover publication,
completion and sampling only; they never cover a handler or finalizer. Sampling is best effort
across slots, while identity and start always agree within a slot. Cancellation abandons a
slot without counting an unfinished attempt. A diagnostic `slotMisses` count should remain
zero for supported runners. `DetailOptions.maxTrackedPartitions` defaults to 256, must be
nonnegative, and reserves the bounded cursor table introduced by the progress extension.

The optional `latency` member appears after the first completed attempt. It contains integer
`count`, `sumSeconds`, and eighteen cumulative `{le, count}` finite buckets from 100
microseconds to 60 seconds. Durations include the handler and all finalization retries and
metrics completion: one observation per message attempt, or per emitted batch in batch mode.
This does not measure queue wait or handler-only latency. Retry decisions and completed
finalization failures still contribute an observation; interrupted attempts do not.

While a slot is occupied, optional `oldestInFlight` contains `messageId`, `startedAt` and
`ageSeconds`. Batch identity is the first retained message's identity. The monotonic start is
converted relative to the handle's initial wall time; later wall-clock adjustments do not
change elapsed age. Timestamp zero is valid. Both detail members are omitted when unavailable;
basic processors retain their existing JSON bytes. Histogram counts and nanosecond sums use
unbounded integers. Scanning costs grow with the configured concurrency bound.

Prometheus adds the `shibuya_message_processing_seconds` histogram, with `_bucket` series
labelled by processor and `le`, `_sum` seconds and exact integer `_count`. Its `+Inf` bucket
is the total count; JSON contains only finite bounds because JSON has no infinite number.
The `shibuya_processor_oldest_in_flight_seconds` gauge exists only while an attempt is in
flight. No zero value is fabricated for processors with detail disabled or no active attempt.

HTTP reads and WebSocket snapshots include freshly sampled age. WebSocket delta comparison
ignores age alone; clients extrapolate `ageSeconds` using elapsed time on their own clock
since receiving the last frame. Identity, completed histograms and all other state changes
continue to emit updates. Detailed accounting remains explicit opt-in; measured overhead and
basic-path acceptance are recorded in [EP-49](../plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md).

Detailed accounting has a measurable cost. EP-49's serial diagnostics observed roughly
46–47% additional allocation; batching amortized this to about 0.4%. Costs vary with workload
and observer count. The default remains basic, and basic-path performance acceptance is
still pending in [EP-49](../plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md).
Preserve the static loop specialization and opaque mode accessor described in
[ADR-0009](../adr/0009-account-for-in-flight-detail-and-latency-with-bounded-synchronized-slots-behind-an-opt-in-detail-level.md).


### Acknowledged cursor progress

With `defaultAppConfig {metricsDetail = MetricsDetailed defaultDetailOptions}`, adapters that set `Envelope.cursor` expose optional `progress` in processor JSON and WebSocket snapshots/updates. `latest` is the last successful AckOk or AckDeadLetter finalization recorded; retry, halt, failed finalization and missing cursors leave it unchanged. `partitions` holds at most `maxTrackedPartitions` keys, atomically enforcing capacity even with concurrent finalizers. Known keys still update after capacity is reached; `truncated` stays true when an additional key cannot fit. Capacity zero provides latest-only reporting. Basic mode and detailed processors without recorded cursors omit progress.

```json
{"progress":{"latest":{"kind":"integer","value":"4210"},"partitions":{"p-0":{"kind":"integer","value":"4210"}},"truncated":false}}
```

Cursor integers use canonical decimal strings, preserving browser identity above 2^53; text cursors use kind `text`. This is completion progress, not a restart checkpoint or global maximum. Per-partition values follow source order only when adapter delivery and processing ordering preserve it. Concurrent completion may move latest backwards. Cursors are opaque and have no Prometheus series.


### Pausing and resuming processors

`pauseProcessor app (ProcessorId "orders")` and `resumeProcessor app (ProcessorId "orders")` return `ControlOutcome`. Successful operations return the intake state captured by the same transaction: `ControlApplied (IntakePaused timestamp)` or `ControlApplied IntakeRunning`. Repeating an operation returns `ControlAlreadyInState` and preserves the original pause timestamp. `isProcessorPaused` returns Nothing for unknown, terminal, draining or uncontrollable registrations.

Pause is an intake admission request. The next source admission waits; an already admitted poll, inbox messages and in-flight handlers may drain. Adapter prefetch and lease renewal remain adapter responsibilities. A pause neither cancels handler work nor stops the process. Graceful shutdown atomically marks processors draining and resumes intake before adapter shutdown; new control requests then return `ControlDraining`.

Paused metrics include live `inFlight`, `maxConcurrency`, `pausedAt` and the unchanged sampled `lastProgress`. Failed and stopped observations take precedence. Prometheus state is 5; health counts drained/progressing paused processors under `paused`. Paused in-flight work that exceeds the existing last-progress threshold remains stuck and fails readiness. New state constructors require consumers with exhaustive decoders to add paused support.

```haskell
outcome <- pauseProcessor app (ProcessorId "orders")
metrics <- getAppMetrics app
_ <- resumeProcessor app (ProcessorId "orders")
```
