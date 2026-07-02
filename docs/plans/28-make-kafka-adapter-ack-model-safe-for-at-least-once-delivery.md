---
id: 28
slug: make-kafka-adapter-ack-model-safe-for-at-least-once-delivery
title: "Make Kafka adapter ack model safe for at-least-once delivery"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Make Kafka adapter ack model safe for at-least-once delivery

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan file lives in the **core repository** at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (repository-relative path
`docs/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery.md`), but every
code change it directs happens in the **adapter repository** at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. When this plan says
"the adapter repository" it means that second directory; when it says "the core repository"
it means the first. Update this plan file (in the core repository) as you make progress;
commit code (in the adapter repository) with the trailers described in Concrete Steps.


## Purpose / Big Picture

Shibuya is a queue-processing framework: an adapter pulls messages from an external queue
system, a user-supplied handler processes each message, and the handler returns an
`AckDecision` — `AckOk` (done), `AckRetry` (try this message again), `AckDeadLetter`
(permanently unprocessable), or `AckHalt` (stop this stream). The Kafka adapter in the
adapter repository translates those decisions into Kafka operations.

Today the translation is unsafe. The adapter maps `AckOk`, `AckRetry`, **and**
`AckDeadLetter` all to the same operation — "store the offset", which tells Kafka "I am
done with everything up to and including this message". That means a handler that returns
`AckRetry` silently **loses the message**: Kafka marks it consumed, the framework does not
redeliver it, and the requested retry delay is discarded. A handler that throws an
exception loses its message the same way (the next successful message stores a higher
offset, committing past the failed one). Additionally, shutting down an idle consumer
throws a spurious error and always burns the full drain timeout, and any Kafka error that
occurs while acknowledging is miscounted as a handler failure.

After this plan is implemented, the adapter delivers genuine **at-least-once** semantics:
every message is either fully processed (handler returned `AckOk`), explicitly and loudly
dropped (handler returned `AckDeadLetter`, with a prominent warning), or the stream halts —
but no message is ever *silently* skipped. `AckRetry` and handler exceptions cause the
message to be redelivered (via a partition seek, defined below). Shutdown of an idle
consumer completes promptly and cleanly. You can see all of this working by running the
new integration tests against a local Redpanda broker (a Kafka-compatible broker the
adapter repository already uses for tests):

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
just process-up          # in one shell: starts Redpanda (Kafka-compatible broker)
cabal test shibuya-kafka-adapter --test-show-details=direct   # in another shell
```


## Progress

- [x] M1: `shutdown` tolerates `RdKafkaRespErrNoOffset` from `commitAllOffsets`. (2026-07-02)
- [x] M1: poll loop checks the shutdown flag inside the poll step; `takeUntilShutdown` removed. (2026-07-02)
- [x] M1: integration test added for idle-topic graceful shutdown completing promptly without error. (2026-07-02)
- [ ] M1: live broker validation — idle-topic graceful shutdown test passes against Redpanda on `localhost:9092`.
- [ ] M1: existing integration suite green with broker; broker-free Adapter/Convert tests passed before broker connection failures; `nix develop -c cabal build all` is green.
- [x] M2: `KafkaAdapterState` (shutdown flag, seek barrier, fatal-error slot) introduced in `Internal.hs`. (2026-07-02)
- [x] M2: `AckRetry` no longer stores the offset; seeks the partition back to the failed offset; honors `RetryDelay`. (2026-07-02)
- [x] M2: seek barrier guards the store path (no offset above a pending retry offset is ever stored) and filters stale records at the source. (2026-07-02)
- [x] M2: integration tests added for in-session `AckRetry` redelivery, abandoned-session redelivery, and handler-exception redelivery. (2026-07-02)
- [ ] M2: live broker validation — `AckRetry` message is redelivered and eventually processed; committed offset never passes it prematurely.
- [ ] M2: live broker validation — handler exception on message N leads to redelivery, never a silent skip.
- [ ] M3: all Kafka calls inside `finalize` are caught and classified; transient errors get bounded retry; persistent errors set the fatal slot and terminate the source stream.
- [ ] M3: failed `pausePartitions` on `AckHalt` no longer cancels the halt.
- [ ] M3: unit tests with a mock `KafkaConsumer` interpreter for classification, bounded retry, and halt hardening.
- [ ] M4: `AckDeadLetter` interim policy implemented (store offset + loud stderr warning + Haddock/README warning).
- [ ] M4: `offsetReset` config field removed; `topics` checked against the live subscription at construction; version bumped to 0.8.0.0 with changelog entry.
- [ ] M4: Serial-only contract, halt/eviction lifecycle, and rebalance boundary documented in Haddocks and README; rebalance callback helper exported.
- [ ] M4: misleading shutdown Haddock (commit-before-drain) corrected.
- [ ] M4: `Convert.hs` computes `headersToList` once; benchmark run before and after with numbers recorded here.
- [ ] Final: full test suite green against a live broker; Outcomes & Retrospective written; master plan checklist items for EP-28 ticked in the core repository.


## Surprises & Discoveries

- 2026-07-02: The sibling core checkout is already `shibuya-core-0.8.0.0`, so the adapter, bench, and jitsurei package bounds had to move from `^>=0.7.0.0` to `^>=0.8.0.0` before Cabal could solve the workspace. The `otel-demo` jitsurei also imported pre-0.8 internal runner modules and now uses the public `runApp`/`mkProcessor`/`waitApp` API.
- 2026-07-02: Plain `cabal build all` typechecked the changed adapter modules but failed at native link with `ld: library not found for -lrdkafka`; `nix develop -c cabal build all` provided the native library and completed successfully.
- 2026-07-02: `nix develop -c cabal test shibuya-kafka-adapter --test-show-details=direct` built the test binary and all broker-free Adapter/Convert tests passed, but the Integration group could not be completed because Redpanda was not running on `localhost:9092` (`Connection refused`). The run was interrupted after repeated broker connection retries.
- 2026-07-02: Cabal splits tasty `--pattern` expressions on spaces when passed via `--test-options`; running the built test binary directly with `--pattern '$2 == "Adapter" || $2 == "Convert"'` selected the broker-free groups successfully. Result: all 23 Adapter/Convert tests passed.


## Decision Log

- Decision: Kafka concurrency safety is achieved by enforcing and documenting Serial-only
  operation, not by building a gap-tracking commit layer.
  Rationale: librdkafka (the C library underneath the Haskell client) commits the highest
  stored offset per partition with no awareness of gaps, so any out-of-order store commits
  past unprocessed messages. A lowest-contiguous-offset tracker (the Broadway-Kafka
  approach) is the correct long-term fix but is new machinery with its own failure modes.
  Decided at the master-plan level; recorded in
  `docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`
  (core repository).
  Date: 2026-07-02

- Decision: A lowest-contiguous-offset gap-tracking commit layer (which would make
  `Async`/`Ahead` concurrency safe) is explicitly excluded future work, not part of this plan.
  Rationale: Scope control at the master-plan level; the Serial constraint closes the
  data-loss hole now.
  Date: 2026-07-02

- Decision: A dead-letter-queue (DLQ) producer is deferred. The adapter documents the
  limitation instead of producing dead-lettered messages to a DLQ topic.
  Rationale: Master-plan scope decision; a DLQ producer needs producer configuration,
  serialization policy, and delivery guarantees of its own.
  Date: 2026-07-02

- Decision: `AckDeadLetter` interim behavior is option (a): store the offset (so the
  consumer moves on, exactly as for `AckOk`) but emit a prominent warning line to stderr
  and carry a prominent Haddock and README warning that dead-lettered messages are
  dropped. Option (b) — treating dead-letter like a halt — was rejected.
  Rationale: Option (b) wedges the partition permanently on a poison message (a message
  that can never be processed), which converts one bad message into a stalled partition.
  Dead-letter accounting already exists in core observability (the per-message trace span
  is set to error status with the dead-letter reason). Loud logging plus documentation is
  the honest interim.
  Date: 2026-07-02

- Decision: `AckRetry` redelivery is implemented with `seekPartitions` (rewind the
  partition's fetch position to the failed message's offset) plus a per-partition
  **seek barrier** that (1) prevents storing any offset greater than the pending retry
  offset and (2) drops stale already-buffered records at the source.
  Rationale: Seeking is coarse — everything after the seek point on that partition is
  redelivered — but duplicates are acceptable under at-least-once and bounded under the
  Serial-only constraint. The barrier is mandatory, not optional: the core framework's
  ingester thread buffers polled messages in a bounded inbox concurrently with
  finalization, so without an ack-side guard a buffered successor finalized `AckOk` after
  the seek would store a higher offset and commit past the failed message again.
  Date: 2026-07-02

- Decision: `RetryDelay` is honored by sleeping (`threadDelay`) inside `finalize` before
  seeking, and the documentation warns that long delays risk consumer-group eviction via
  `max.poll.interval.ms`.
  Rationale: Under Serial-only operation, delaying finalize delays exactly the partition
  that asked for a retry, which is the requested semantics. A partition-pause/resume dance
  would add state for no additional guarantee. The eviction hazard (defined in Context) is
  documented rather than engineered around, because delays are expected to be small
  (`RetryDelay 0` from EP-23's exception path is the common case).
  Date: 2026-07-02

- Decision: Kafka errors raised by operations inside `finalize` never escape `finalize`.
  Transient errors get a bounded retry (3 attempts, 50 ms apart); persistent or fatal
  errors are written to a shared fatal-error slot which the poll loop observes and turns
  into a stream-terminating `throwError`, surfacing as an adapter failure rather than a
  handler failure.
  Rationale: The core's `processOne` wraps handler-plus-finalize in `catchAny`
  (`shibuya-core/src/Shibuya/Runner/Supervised.hs` line 591 in the core repository), and
  effectful's static `Error` effect is implemented with runtime exceptions, so anything
  thrown from `finalize` is caught there and miscounted as a handler failure — and, worse,
  a throwing `pausePartitions` on `AckHalt` prevents core from ever seeing
  `Right (AckHalt _)`, silently cancelling the halt. Escaping through the *source stream*
  instead is the only path core treats as an adapter/ingest failure.
  Date: 2026-07-02

- Decision: Remove the dead `offsetReset` config field; keep `topics` but verify it against
  the live subscription at adapter construction, logging a stderr warning on mismatch.
  Rationale: The caller owns the `Subscription` passed to `runKafkaConsumer` (including its
  offset-reset policy); the adapter's copy of `offsetReset` is never read and can only
  mislead. `topics` is used for `adapterName` (observability) and is worth a cheap
  consistency check via the `subscription` query, which reflects the subscription
  registered at consumer creation.
  Date: 2026-07-02

- Decision: Keep the shutdown-time `commitAllOffsets` where it is (at shutdown-signal
  time) and fix the misleading Haddock instead of moving the commit after drain.
  Rationale: The `Adapter` record in core (`shibuya-core/src/Shibuya/Adapter.hs`) has only
  `source` and `shutdown` — there is no post-drain hook. Offsets stored during the drain
  window are flushed by the consumer's close path: `runKafkaConsumer` (kafka-effectful)
  calls `closeConsumer` when its scope ends, and librdkafka's consumer close commits final
  stored offsets when auto-commit is enabled, which is the adapter's documented operating
  mode (`noAutoOffsetStore` = manual store + automatic commit). The early commit is
  harmless; the Haddock at `Shibuya/Adapter/Kafka.hs` (adapter repository) must stop
  implying it is the *final* commit.
  Date: 2026-07-02

- Decision: No changes to kafka-effectful are needed.
  Rationale: Research confirmed `seekPartitions` is already exposed by
  `Kafka.Effectful.Consumer.Effect` (constructor `SeekPartitions`, smart constructor
  `seekPartitions :: [TopicPartition] -> Timeout -> Eff es ()`) and interpreted at
  `Kafka.Effectful.Consumer.Interpreter` line 85 over hw-kafka-client's
  `seekPartitions`. The milestone reserved for adding a wrapper is therefore dropped.
  Date: 2026-07-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The two repositories and how they relate

The **core repository** (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) contains
`shibuya-core`, the framework: `runApp` starts one supervised processor per queue, each
processor runs an ingester thread that pulls an adapter's `source` stream into a bounded
inbox, and a processing loop that calls the user handler on each message and then calls
`finalize` on the message's `AckHandle` with the handler's `AckDecision`.

The **adapter repository** (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`)
contains three packages: `shibuya-kafka-adapter` (the library this plan changes),
`shibuya-kafka-adapter-bench` (micro-benchmarks for the conversion hot path), and
`shibuya-kafka-adapter-jitsurei` (runnable examples). The library has four modules, all
under `shibuya-kafka-adapter/src/` in the adapter repository:

- `Shibuya/Adapter/Kafka.hs` — public entry point `kafkaAdapter`, adapter assembly,
  shutdown, and the module-level documentation.
- `Shibuya/Adapter/Kafka/Internal.hs` — `kafkaSource` (the poll loop), `mkAckHandle`
  (decision → Kafka operation mapping), `mkIngested`, `ingestedStream`.
- `Shibuya/Adapter/Kafka/Config.hs` — `KafkaAdapterConfig` (`topics`, `pollTimeout`,
  `batchSize`, `offsetReset`) and `defaultConfig`.
- `Shibuya/Adapter/Kafka/Convert.hs` — `ConsumerRecord` → `Envelope` conversion,
  trace-header extraction, timestamp conversion.

The adapter builds against the in-tree core via `cabal.project.local` in the adapter
repository, which adds `../shibuya/shibuya-core` as a local package. The library declares
`shibuya-core ^>=0.7.0.0`.

The adapter sits on two libraries whose sources are registered locally (find them with
`mori registry search kafka`): **kafka-effectful**
(`/Users/shinzui/Keikaku/bokuno/kafka-effectful`) provides the `KafkaConsumer` effect —
operations like `pollMessageBatch`, `storeOffsetMessage`, `commitAllOffsets`,
`pausePartitions`, `seekPartitions` — whose interpreter
(`src/Kafka/Effectful/Consumer/Interpreter.hs`) throws every Kafka failure through
effectful's `Error KafkaError` effect. **hw-kafka-client**
(`/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project/hw-kafka-client`) is the
binding to librdkafka, the C client library. The helper `skipNonFatal` from
**hw-kafka-streamly** filters benign errors (poll timeouts, partition EOF) out of the poll
stream; its `isFatal` predicate (in
`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly/src/Kafka/Streamly/Stream.hs`)
classifies configuration/auth/SSL errors as fatal and everything else as non-fatal.

### Kafka terms you must understand (defined here, used throughout)

**Partition and offset.** A Kafka *topic* is split into *partitions*, each an append-only
log. Every message in a partition has a monotonically increasing integer *offset*.
Consuming is just reading a partition forward from some offset.

**Consumer group.** Consumers that share a *group id* form a *consumer group*. The broker
assigns each partition to exactly one member of the group. Progress is tracked per group,
per partition, as a single *committed offset* meaning "everything below this offset is
done".

**Offset store vs. offset commit.** These are two distinct steps in librdkafka.
*Storing* an offset (`storeOffsetMessage`) is a local, in-memory note: "when you next
commit, commit this". *Committing* (`commitAllOffsets`, or the automatic commit timer)
sends the stored offsets to the broker durably. The adapter runs in the mode the docs call
`noAutoOffsetStore`: automatic *commits* stay on, automatic *stores* are off, and the
adapter stores offsets manually as messages are acknowledged. Crucially,
`storeOffsetMessage` stores *offset + 1* (hw-kafka-client's
`topicPartitionFromMessageForCommit` adds one), because a committed offset names the *next*
message to read. Also crucially, librdkafka keeps only the **highest** stored offset per
partition — storing offset 7 after offset 3 means 4, 5, and 6 are considered done whether
or not they were processed. This is why the adapter is only safe with serial processing.

**Seek.** `seekPartitions` moves the consumer's *fetch position* for a partition to a given
offset. Subsequent polls redeliver messages from that offset forward. It does not touch
the committed offset. This is the mechanism this plan uses for retry: seek back to the
failed message and let Kafka redeliver it (and, coarsely, everything after it on that
partition — acceptable duplicates under at-least-once delivery, which promises every
message is processed *at least* once, possibly more).

**Rebalance.** When group membership changes (a consumer joins, leaves, or is evicted), the
broker *rebalances*: it revokes partitions from members and reassigns them. A consumer can
install a *rebalance callback* to observe assignment and revocation events. In
hw-kafka-client, callbacks are registered in `ConsumerProperties` via
`setCallback (rebalanceCallback ...)` **before** the consumer is created — they cannot be
installed after the fact, and in this adapter's architecture the caller (not the adapter)
owns the `ConsumerProperties` passed to `runKafkaConsumer`.

**max.poll.interval.ms.** A librdkafka setting (default 300000 ms = 5 minutes). If the
application stops polling for longer than this, the broker assumes the consumer is dead,
evicts it from the group, and rebalances its partitions to other members. This matters
twice in this plan: after `AckHalt` the processor stops polling, so eviction follows within
about five minutes; and a very long `RetryDelay` that blocks the pipeline can trigger the
same eviction.

**Drain timeout.** When the framework shuts down (`stopApp`/`stopAppGracefully` in
`shibuya-core/src/Shibuya/App.hs`, core repository), it first calls every adapter's
`shutdown`, then waits up to `drainTimeout` (default 30 s) for processors to finish
in-flight messages, then force-stops. Note the ordering: `adapter.shutdown` runs **first**,
so an exception thrown from it aborts the whole graceful-shutdown sequence.

### The five defects, precisely located (all paths in the adapter repository)

**Defect 1 (critical): `AckRetry` silently drops the message.** In
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, `mkAckHandle` (lines 70–78)
maps `AckOk`, `AckRetry _`, and `AckDeadLetter _` all to `storeOffsetMessage cr`. For
`AckRetry`, that stores *failed offset + 1* — Kafka will commit past the message, the core
does not redeliver (redelivery is the adapter's job), and the `RetryDelay` is discarded.
The module doc (lines 61–64) states this openly ("Kafka cannot un-read").

**Defect 2 (critical): handler exceptions skip-and-commit-past.** Before core EP-23, a
handler exception meant `finalize` was never called for that message; the next `AckOk`
stored a higher offset, committing past the failed one. Core EP-23 (see Interfaces and
Dependencies) changes core so a handler exception finalizes with `AckRetry (RetryDelay 0)`
on the single-message path — which lands squarely on defect 1. Fixing defect 1 fixes
defect 2, and this plan proves it with an integration test.

**Defect 3 (major): `AckDeadLetter` is indistinguishable from success.** Same
`storeOffsetMessage` mapping; no DLQ producer exists (deferred by master-plan decision), no
warning is emitted. Also, `Envelope.attempt` is `Nothing`
(`Shibuya/Adapter/Kafka/Convert.hs` line 68) — Kafka exposes no per-message delivery
counter, so handlers cannot count redeliveries via `attempt` and therefore cannot cap
retries; this stays true after this plan and must be documented.

**Defect 4 (major): shutdown throws on an empty offset store.** The adapter's `shutdown`
(`Shibuya/Adapter/Kafka.hs` lines 121–123) calls `commitAllOffsets OffsetCommit`.
hw-kafka-client's `commitAllOffsets` returns `Just (KafkaResponseError
RdKafkaRespErrNoOffset)` when nothing has been stored (an idle consumer), and
kafka-effectful's interpreter (`Interpreter.hs` line 76, `throwOnJust`) throws it through
`Error KafkaError`. Because `adapter.shutdown` runs first in `stopAppGracefully`, an idle
consumer's `stopApp` aborts the entire core shutdown sequence.

**Defect 5 (major): shutdown of an idle topic burns the full drain timeout.**
`takeUntilShutdown` (`Shibuya/Adapter/Kafka.hs` lines 127–135) uses `Stream.takeWhileM`,
which checks the flag *between stream elements*. On an idle topic, `pollMessageBatch`
returns `[]` forever, `Stream.concatMap Stream.fromList` produces no elements, and the
check never runs — the stream never ends, and every shutdown waits out the full drain
timeout.

**Defect 6 (major): ack-path Kafka errors escape as handler exceptions.** Every operation
`mkAckHandle` performs (`storeOffsetMessage`, `pausePartitions`) throws through `Error
KafkaError` on failure. Core's `processOne`
(`shibuya-core/src/Shibuya/Runner/Supervised.hs` lines 590–600, core repository) wraps
handler-plus-finalize in `catchAny`, so those errors are recorded as handler failures.
Worst case: `AckHalt` whose `pausePartitions` throws — core only sets its halt flag on a
*successful* `Right (AckHalt _)` (line 633), so the halt is silently cancelled and
processing continues on a stream the handler declared must stop.

**Minor defects.** `offsetReset` in `Config.hs` (line 28) is never read anywhere; `topics`
(line 22) is used only to build `adapterName` and is never checked against the caller's
actual `Subscription`. `Convert.hs` computes `headersToList cr.crHeaders` twice per message
(line 67 directly, line 114 inside `extractTraceHeaders`). The Haddock at
`Shibuya/Adapter/Kafka.hs` line 102 ("On shutdown, `commitAllOffsets` flushes any stored
offsets") misleads: messages finalized *during* the drain window store offsets after that
commit; those are flushed by the consumer close path, not by the adapter's shutdown commit.
No rebalance callback exists, so assignment changes are invisible in logs and adapter
bookkeeping is never informed of revocations.

### How the core consumes the adapter (why the fix must be shaped this way)

Two core behaviors constrain the design. First, the **ingester runs concurrently with
finalization**: polled messages sit in a bounded inbox while earlier messages are being
processed. When `AckRetry` seeks partition P back to offset N, messages N+1..N+k from the
same poll batch may already be buffered in the inbox or mid-stream; they will still reach
the handler (a duplicate — fine) and their `AckOk` would store an offset above N (NOT fine
— it re-creates the commit-past-failure hole). Hence the *seek barrier*: after seeking P to
N, the adapter must refuse to store any offset > N for P until the redelivered N has been
finalized. Second, **anything thrown inside `finalize` is caught by core's `catchAny`** and
miscounted, so adapter-fatal conditions must reach core through the *source stream* (which
core treats as an ingest failure), not through `finalize`.

### Test environment

Integration tests run against a real broker. `process-compose.yaml` in the adapter
repository root starts Redpanda (a Kafka-API-compatible broker) via
`rpk container start -n 1 --kafka-ports 9092` — this requires a running Docker daemon —
plus a Jaeger instance for traces. The Justfile wraps it: `just process-up` (foreground;
Ctrl-C or `just process-down` to stop). Tests create their own uniquely named topics via
`rpk topic create` (see `createTopic` in `shibuya-kafka-adapter/test/Kafka/TestEnv.hs`,
which shells out to `rpk`), produce with a real producer, and consume through the adapter
against `localhost:9092`. The suite (`test-suite shibuya-kafka-adapter-test` in
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`) currently contains happy-path
integration tests only (`IntegrationTest.hs`: produce-consume, offset commit,
multi-partition, batch polling, graceful shutdown with messages present), pure conversion
tests (`ConvertTest.hs`), and broker-free stream tests (`AdapterTest.hs`).


## Plan of Work

The work is four milestones. Each is independently shippable and verifiable, ordered so the
smallest, most urgent fixes land first.

### Milestone 1 — Shutdown correctness (defects 4 and 5)

Scope: make graceful shutdown of an idle consumer prompt and error-free. At the end of this
milestone, calling the adapter's `shutdown` on a consumer that has stored nothing does not
throw, and a source stream over an idle topic ends within roughly one poll interval of the
shutdown signal instead of never.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` (adapter repository), change the
`shutdown` field of the returned `Adapter` to catch and swallow exactly the no-offset case.
kafka-effectful throws `KafkaResponseError RdKafkaRespErrNoOffset` (import
`RdKafkaRespErrT (..)` from `Kafka.Consumer`, which re-exports it) through `Error
KafkaError`; use `catchError` from `Effectful.Error.Static` and rethrow anything else:

```haskell
shutdown = do
    liftIO $ atomically $ writeTVar shutdownVar True
    commitAllOffsets OffsetCommit
        `catchError` \callStack err ->
            case err of
                KafkaResponseError RdKafkaRespErrNoOffset -> pure ()
                _ -> throwError err  -- preserve everything else
```

(The exact `catchError` handler shape is `CallStack -> e -> Eff es a` in effectful's static
Error; adapt to the version in use — check `Effectful.Error.Static` haddocks in the build
plan if the arity differs.)

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, move the shutdown check
*inside the poll step*. Change `kafkaSource` to take the shutdown `TVar Bool` and replace
the unconditional `Stream.repeatM pollBatch` with an unfold that consults the flag before
each poll and ends the stream when it is set:

```haskell
kafkaSource ::
    (KafkaConsumer :> es, IOE :> es) =>
    TVar Bool ->
    KafkaAdapterConfig ->
    Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
kafkaSource shutdownVar config =
    skipNonFatal $
        Stream.unfoldrM step ()
            & Stream.concatMap Stream.fromList
  where
    step () = do
        stop <- liftIO $ readTVarIO shutdownVar
        if stop
            then pure Nothing
            else do
                batch <- pollMessageBatch config.pollTimeout config.batchSize
                pure (Just (batch, ()))
```

Because the flag is now checked once per *poll* (which returns within `pollTimeout` even
when empty, default 1000 ms), an idle stream ends within about one poll timeout of the
signal. Delete `takeUntilShutdown` from `Shibuya/Adapter/Kafka.hs` and pass `shutdownVar`
into `kafkaSource` instead. Keep the `TVar` creation in `kafkaAdapter`.

Add an integration test to
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`: create a topic,
produce **nothing**, start draining the adapter source in an `async` (the `async` package
is already a test dependency), sleep briefly (say 500 ms), call `shutdown`, and assert that
(1) the drain completes within a bound of roughly three poll timeouts (use a short
`pollTimeout` such as 500 ms in the test config and `System.Timeout.timeout` or a
`race`-with-delay around the wait), and (2) the whole computation returns `Right ()` — i.e.
the empty-store commit did not throw. This single test fails before this milestone in both
ways (it times out, and if forced past that it errors with `RdKafkaRespErrNoOffset`) and
passes after.

Acceptance: `cabal test shibuya-kafka-adapter` (broker running) is green including the new
test; the new test demonstrably fails if you revert either fix.

### Milestone 2 — Seek-based redelivery for `AckRetry` and handler exceptions (defects 1 and 2)

Scope: `AckRetry` stops storing the offset and instead causes redelivery. At the end of
this milestone, a message finalized with `AckRetry` is delivered again by Kafka within the
same consumer session, no offset at or above it is committed until it is finally resolved,
and `RetryDelay` is honored.

First, introduce shared adapter state in `Internal.hs`. Group the mutable pieces so they
can be threaded to both the ack handles and the poll loop (and, in M4, to the rebalance
callback helper):

```haskell
-- | Mutable state shared between the poll loop, the ack handles, and the
-- (optional) rebalance callback. One value per adapter instance.
data KafkaAdapterState = KafkaAdapterState
    { shutdownVar :: !(TVar Bool)
    -- ^ Set by 'shutdown'; poll loop ends the stream when it sees True.
    , seekBarrier :: !(IORef (Map (TopicName, PartitionId) Offset))
    -- ^ Per-partition retry barrier: while an entry (P, N) is present, no
    -- offset above N may be stored for P, and records from P above N are
    -- dropped at the source (they are stale pre-seek buffer contents).
    , fatalError :: !(IORef (Maybe KafkaError))
    -- ^ Set by the ack path when a Kafka error is persistent (M3); the poll
    -- loop observes it and terminates the stream by throwing it.
    }

newKafkaAdapterState :: IO KafkaAdapterState
```

(`Data.Map.Strict` from `containers` — already a dependency. `Offset` and `PartitionId`
come from `Kafka.Consumer.Types` / `Kafka.Types`.)

Rewrite `mkAckHandle` to take the state and the config. The `AckRetry` arm must do, in
order: (1) if the delay is positive, `liftIO (threadDelay micros)`; (2) atomically record
the barrier entry `(cr.crTopic, cr.crPartition) -> cr.crOffset` via
`atomicModifyIORef'`; (3) seek the partition back to the failed message:

```haskell
AckRetry (RetryDelay delay) -> do
    when (delay > 0) $
        liftIO $ threadDelay (floor (delay * 1_000_000))
    liftIO $ atomicModifyIORef' state.seekBarrier $ \m ->
        (Map.insert (cr.crTopic, cr.crPartition) cr.crOffset m, ())
    seekPartitions
        [ TopicPartition
            { tpTopicName = cr.crTopic
            , tpPartition = cr.crPartition
            , tpOffset = PartitionOffset (unOffset cr.crOffset)
            }
        ]
        config.pollTimeout
```

The barrier entry must be written **before** the seek so there is no window in which
redelivered-or-stale successors can store past the failed offset. `seekPartitions` is the
kafka-effectful smart constructor (`Kafka.Effectful.Consumer.Effect`, already exported —
no upstream changes needed); it takes hw-kafka-client's `TopicPartition` record
(`tpTopicName`, `tpPartition`, `tpOffset :: PartitionOffset`) and a `Timeout`. Note the
seek targets the failed offset itself (`PartitionOffset (unOffset cr.crOffset)`), *not*
offset + 1 — unlike stores, we want to re-read this exact message. Reuse
`config.pollTimeout` as the seek timeout (one config knob fewer; record in the Decision Log
if you find a reason to split it).

Guard the store path. Write one helper used by the `AckOk` and `AckDeadLetter` arms:

```haskell
-- | Store the record's offset unless a seek barrier for its partition
-- forbids it. Clears the barrier when finalizing the barrier message itself
-- (or, defensively, anything at or below it).
storeGuarded state cr = do
    proceed <- liftIO $ atomicModifyIORef' state.seekBarrier $ \m ->
        case Map.lookup (cr.crTopic, cr.crPartition) m of
            Nothing -> (m, True)
            Just barrierOff
                | cr.crOffset <= barrierOff ->
                    (Map.delete (cr.crTopic, cr.crPartition) m, True)
                | otherwise -> (m, False)   -- stale successor: do NOT store
    when proceed $ storeOffsetMessage cr
```

Semantics: no barrier → store normally. Finalizing the retried message itself (offset equal
to the barrier; `<=` is defensive for post-rebalance re-reads from an older committed
offset) → clear the barrier and store. Finalizing a *stale* successor (offset above the
barrier — a message that was already buffered when the seek happened) → skip the store
entirely; the message will be redelivered after the seek and stored then. If that
redelivered retry fails again with `AckRetry`, the arm above simply reinstates the same
barrier — the scheme is idempotent under repeated failures.

Also drop stale records at the source, to avoid pointlessly re-processing the buffered
remainder. In the adapter assembly (`Shibuya/Adapter/Kafka.hs`), between `kafkaSource` and
`ingestedStream`, insert a `Stream.filterM`-style stage (write it in `Internal.hs` as
`dropStaleRecords :: KafkaAdapterState -> Stream ... -> Stream ...`) that passes `Left`
errors through untouched and, for `Right cr`, drops the record when a barrier entry exists
for its partition with `cr.crOffset > barrier` (do **not** clear the barrier here — only
the finalize path clears it, because clearing must coincide with the store decision). This
stage is an optimization plus duplicate-reduction measure; the correctness load is carried
by `storeGuarded`. Note this filter cannot replace `storeGuarded`: records already sitting
in core's bounded inbox have passed the filter before the seek happened.

`mkAckHandle` and `mkIngested` gain `KafkaAdapterState` (and `IOE :> es`) parameters;
`kafkaAdapter` creates the state with `newKafkaAdapterState` and threads it everywhere.
The `AckHalt` arm stays `pausePartitions [(cr.crTopic, cr.crPartition)]` in this milestone
(hardened in M3). Update the `mkAckHandle` Haddock (currently lines 57–64) to describe the
new mapping truthfully.

Add two integration tests. **Test A (AckRetry redelivery), broker required:** produce
`["r-1", "r-2", "r-3"]`; drive the adapter source directly (like `consumeN` in
`test/Kafka/TestEnv.hs`, but with a stateful decision function): finalize `AckRetry
(RetryDelay 0)` the first time payload `r-2` is seen, `AckOk` otherwise. Consume until 4
finalizations have happened (r-1, r-2-fail, r-2-again, r-3 — allow for the coarse-seek
duplicates by consuming until each of the three payloads has been `AckOk`d at least once,
with a cap). Assert `r-2` was delivered at least twice; then shutdown, and open a *new*
consumer in the same group asserting zero redelivery (i.e. the committed offset covers all
three messages — reuse the pattern from `testOffsetCommit`). Also assert the inverse
safety property: kill the first session immediately after the `AckRetry` finalize (before
`r-2` is `AckOk`d) in a *separate* scenario, and assert a new consumer in the same group
**does** see `r-2` again — proving no offset was committed past the failed message.
**Test B (handler-exception redelivery), broker plus core EP-23 required:** run the full
framework (`Shibuya.App.runApp` with a real processor, the pattern shown in the
`Shibuya/Adapter/Kafka.hs` module Haddock) with a handler that throws an exception the
first time it sees message `n-2` and returns `AckOk` afterwards; assert all three messages
are eventually processed exactly-or-more than once each and that `n-2` is never skipped.
This test encodes EP-23's contract (handler exception ⇒ core finalizes `AckRetry
(RetryDelay 0)`); it can only pass once the shibuya-core the adapter builds against
includes EP-23. Until then, mark it pending/expected-fail with a comment naming EP-23, and
record the state in Progress. The `cabal.project.local` already points at the in-tree core,
so "the pin includes EP-23" means "EP-23 is merged in the sibling core checkout".

Acceptance: both tests green (Test B possibly gated as described); the pre-existing suite
green; reverting the `AckRetry` arm to `storeOffsetMessage` makes Test A's
committed-offset assertion fail.

### Milestone 3 — Ack-path error classification and halt hardening (defect 6)

Scope: no Kafka error thrown by finalize operations ever escapes `finalize`; transient
errors are retried a bounded number of times; persistent errors terminate the adapter
stream as an adapter failure; a failing `pausePartitions` can no longer cancel a halt.

In `Internal.hs`, write one wrapper and route **every** Kafka call inside `mkAckHandle`
(`storeOffsetMessage` via `storeGuarded`, `seekPartitions`, `pausePartitions`) through it:

```haskell
-- | Run a Kafka action from the ack path. Transient errors are retried up
-- to 3 times, 50 ms apart. A persistent (or immediately fatal) error is
-- recorded in 'fatalError' and the function returns normally: finalize must
-- never throw, because core's catchAny would misattribute the error to the
-- handler (and a throwing AckHalt arm would cancel the halt). The poll loop
-- turns the recorded error into a stream-terminating throwError.
ackAttempt ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState -> Eff es () -> Eff es ()
```

Implementation sketch: loop up to 3 attempts; run the action under `catchError
@KafkaError`; on success return; on error, if `isFatal err` (the hw-kafka-streamly
predicate — configuration/auth/SSL-class errors that retrying cannot fix) give up
immediately, otherwise sleep 50 ms and retry; when attempts are exhausted or the error was
fatal, `liftIO $ atomicWriteIORef state.fatalError (Just err)` and return `()`. The
constants (3 attempts, 50 ms) are deliberate: long enough to ride out a broker hiccup
between two heartbeats, short enough that Serial throughput degrades visibly rather than
hanging. Do not make them configurable in this plan; note it as future work if it itches.

In the poll step from M1 (`kafkaSource`), check `fatalError` alongside `shutdownVar` before
each poll: if a fatal error is recorded, `throwError err` (the `Error KafkaError :> es`
constraint is already available where `kafkaSource` is assembled — add it to the signature).
That throw happens in the ingester's stream, which core treats as an ingest/adapter
failure — the supervisor and the caller's `runError @KafkaError` scope observe it — rather
than as a handler failure.

The `AckHalt` arm becomes `ackAttempt state (pausePartitions [...])`. Net effect on the
halt-cancellation bug: `finalize` now always returns normally, so `processOne` in core
always receives `Right (AckHalt reason)` and always sets the halt flag; if the pause
itself persistently failed, the stream additionally terminates via `fatalError` — the halt
is *escalated*, never *cancelled*.

Add broker-free unit tests in a new module
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AckHandleTest.hs` (wire it into
`test/Main.hs` and the cabal `other-modules`). Build a mock interpreter for the
`KafkaConsumer` effect with `Effectful.Dispatch.Dynamic.interpret` (the effect's
constructors are exported from `Kafka.Effectful.Consumer.Effect`) backed by `IORef`s that
script failures: `StoreOffsetMessage` fails N times then succeeds; `PausePartitions`
always fails with a non-fatal error; `SeekPartitions` records its arguments. Unmatched
constructors can `error "not exercised"`. Assert: (1) two transient store failures then
success → offset stored, no fatal recorded, three attempts observed; (2) persistent
transient failure → exactly 3 attempts, `fatalError` set, `finalize` returned normally;
(3) immediately fatal error (e.g. `KafkaBadConfiguration`) → 1 attempt, `fatalError` set;
(4) `AckHalt` with persistently failing pause → `finalize` returns normally (halt not
cancelled) and `fatalError` is set; (5) `AckRetry` → `SeekPartitions` called with the
failed message's exact offset and no store performed. These tests also pin the M2 barrier
semantics cheaply (feed a synthetic successor record through `storeGuarded` with a barrier
set; assert no store).

Acceptance: unit tests green without a broker (`cabal test shibuya-kafka-adapter` runs
them regardless; the integration groups need the broker); full suite green with the broker
up.

### Milestone 4 — Dead-letter interim policy, config cleanup, documentation, convert micro-fix (defect 3 and the minors)

Scope: everything remaining. At the end, the adapter's documentation tells the truth about
every limitation, dead-letters are loud, dead config is gone, a rebalance callback helper
exists, and the conversion hot path does not duplicate work.

**AckDeadLetter (decision (a), see Decision Log).** In `mkAckHandle`, the `AckDeadLetter
reason` arm stores the offset via `storeGuarded` (same as `AckOk` — the consumer must move
on) but first emits one unmissable line to stderr via `liftIO`:

```haskell
AckDeadLetter reason -> do
    liftIO $ hPutStrLn stderr $
        "[shibuya-kafka-adapter] WARNING: dead-lettered message DROPPED (no DLQ producer): "
            <> show (cr.crTopic, cr.crPartition, cr.crOffset)
            <> " reason=" <> show reason
    storeGuarded state cr
```

Core observability already marks the per-message trace span as an error with the
dead-letter reason (`processOne`, core repository), so traces carry the accounting; the
stderr line is the belt to that suspender. Add a prominent "Dead letters are dropped"
subsection to the `Shibuya.Adapter.Kafka` module Haddock and to `README.md` (adapter
repository root), stating: there is no DLQ producer (deferred; master-plan decision); an
`AckDeadLetter` message's offset is committed and the message is unrecoverable from the
group's perspective; and `Envelope.attempt` is always `Nothing` because Kafka has no
per-message delivery counter, so handlers **cannot cap retries by counting attempts** —
a handler that must bound retries needs its own store, or should return `AckHalt` to stop
the stream. Leave `attempt = Nothing` in `Convert.hs` as is (verified: no Kafka header or
client mechanism supplies a redelivery count).

**Config cleanup.** In `Shibuya/Adapter/Kafka/Config.hs`, delete the `offsetReset` field
and its `defaultConfig` line and the `Kafka.Consumer.Types (OffsetReset (..))` import; the
caller's `Subscription` owns offset-reset policy (note this in the field-less record's
Haddock and in the README). Keep `topics`, but in `kafkaAdapter` add a construction-time
consistency check: call `subscription` (the kafka-effectful query; reflects the
subscription registered at consumer creation), compare the topic names against
`config.topics`, and on mismatch print a stderr warning naming both sets (do not fail —
the field is observability metadata, and a hard error would break callers who intentionally
subscribe wider). If the query proves unreliable in practice (e.g. empty before group
join), downgrade to documentation-only and record why in the Decision Log. Update the two
test files and any jitsurei examples that construct `KafkaAdapterConfig` with `offsetReset`
(grep the adapter repository for `offsetReset` — `test/Kafka/TestEnv.hs` line ~177 and
`IntegrationTest.hs` construct it; their *consumer-properties* `offsetReset` from
kafka-effectful's `Subscription` builder is a different thing and stays). This is an API
break: bump `version` in `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` to `0.8.0.0`
and add a `CHANGELOG.md` entry summarizing all behavior changes in this plan (retry
semantics, dead-letter warning, shutdown fixes, removed field).

**Serial-only contract and lifecycle documentation.** Rewrite the `Shibuya.Adapter.Kafka`
module Haddock's "Message Lifecycle" (currently lines 27–34, whose claims 4 and 5 are
falsified by M2/M4) and "AckHalt Partition Pause Semantics" sections, and add a "Serial
Operation Required" section stating, in plain language: librdkafka commits the highest
stored offset per partition with no gap tracking, so any concurrency that lets a later
message finalize before an earlier one can commit past an unprocessed or halted message —
therefore this adapter must be run with `Serial` concurrency only; core's `validatePolicy`
(EP-24, core repository, `shibuya-core/src/Shibuya/Policy.hs`) rejects
`PartitionedInOrder` with `Async`, and this adapter's contract additionally forbids
`Async`/`Ahead` outright until the excluded gap-tracking layer exists (Decision Log). The
adapter cannot verify core's `Concurrency` choice at construction — the `Adapter` record
(core repository, `shibuya-core/src/Shibuya/Adapter.hs`) carries only a name, a stream,
and a shutdown action, and the policy lives in the processor the *caller* assembles — so
this is a documented contract, not a runtime guard; state that explicitly. Document the
halt lifecycle honestly: after `AckHalt`, the partition is paused and the processor stops;
polling therefore stops; after `max.poll.interval.ms` (librdkafka default 300000 ms = 5
minutes) the broker evicts this consumer from the group and rebalances, so another group
member (if any) resumes the partition from the last committed offset — the paused state
does not outlive the session, and a single-member group simply stalls until restart.
Mirror the key points in `README.md`.

**Rebalance callback helper (boundary: logging and bookkeeping only).** Export from
`Shibuya.Adapter.Kafka` a helper the *caller* installs into their `ConsumerProperties`
(callbacks must be registered before consumer creation, so the adapter cannot install it
itself):

```haskell
-- | A rebalance callback for use with
-- 'Kafka.Consumer.setCallback' . 'Kafka.Consumer.rebalanceCallback':
-- logs every assignment/revocation to stderr and clears seek-barrier
-- entries for revoked partitions. Full cooperative rebalance handling
-- (fencing in-flight work) is out of scope for this adapter.
kafkaRebalanceHandler ::
    KafkaAdapterState -> Kafka.KafkaConsumer -> RebalanceEvent -> IO ()
```

On `RebalanceRevoke ps` it deletes those partitions' entries from `seekBarrier` (defense in
depth — the `<=` rule in `storeGuarded` already self-heals stale barriers after
reassignment); on every event it prints one stderr line. To make the state reachable by
both the callback (built before the consumer) and the adapter (built inside the consumer
scope), export `newKafkaAdapterState :: IO KafkaAdapterState` and add `kafkaAdapterWith ::
KafkaAdapterState -> KafkaAdapterConfig -> Eff es (Adapter es (Maybe ByteString))`;
`kafkaAdapter config` keeps its signature and becomes `newKafkaAdapterState >>= \st ->
kafkaAdapterWith st config` (via `liftIO`). Document in the Haddock that installing the
callback is optional and what is lost without it (no rebalance visibility; barrier
self-healing still applies). State the boundary explicitly in the Haddock: cooperative
incremental rebalance strategies and revocation-aware in-flight fencing are **out of
scope**.

**Shutdown Haddock fix.** Rewrite the paragraph at `Shibuya/Adapter/Kafka.hs` (currently
around line 100–108): shutdown commits offsets stored *so far*; messages finalized during
the drain window store offsets afterwards, and those are flushed by the consumer close
path (`runKafkaConsumer`'s `closeConsumer` on scope exit, whose librdkafka close performs a
final commit under the auto-commit mode this adapter requires); therefore the caller must
let `runKafkaConsumer`'s scope end normally after `stopApp` returns. Keep the existing
warning that `shutdown` must run while the `KafkaConsumer` effect is in scope.

**Convert micro-fix.** In `Shibuya/Adapter/Kafka/Convert.hs`, compute `headersToList
cr.crHeaders` once in `consumerRecordToEnvelope`, bind it, and use it for both the
`headers` field and trace extraction. Add `extractTraceHeadersFromList ::
[(ByteString, ByteString)] -> Maybe TraceHeaders` containing the current lookup logic;
keep `extractTraceHeaders :: Headers -> Maybe TraceHeaders` as a thin wrapper (it is
exported and used by tests and the benchmark). Run the benchmark before and after the
change from the adapter repository root — `cabal bench shibuya-kafka-adapter-bench` — and
paste the `consumerRecordToEnvelope` mean-time lines for both runs into Surprises &
Discoveries (tasty-bench prints e.g. `consumerRecordToEnvelope/with headers: OK ... 812 ns`);
the point of running both is honesty, not a target number.

Acceptance: full suite green with the broker up; `cabal haddock shibuya-kafka-adapter`
builds without new warnings; README and Haddocks contain the Serial-only, dead-letter,
attempt-is-Nothing, halt/eviction, and shutdown-ordering statements; benchmark numbers
recorded in this file.


## Concrete Steps

All build/test commands run from the adapter repository root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`, inside its dev shell
(`direnv allow` once, or prefix commands with `nix develop -c`).

Bring up the broker (requires a running Docker daemon; keep this shell open):

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
just process-up
```

Expected (abridged) output ends with the Redpanda readiness probe passing:

```text
redpanda: rpk container start ... Cluster started!
readiness probe succeeded for redpanda
```

`just process-down` stops it. The integration tests create their own uniquely named topics
via `rpk` (see `test/Kafka/TestEnv.hs`); `just create-topics` is only needed for the
jitsurei examples.

Build and test in a second shell:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
cabal build all
cabal test shibuya-kafka-adapter --test-show-details=direct
```

A green run ends with tasty's summary:

```text
All N tests passed (XX.XXs)
```

A broker-down run fails the Integration group with connection errors mentioning
`localhost:9092` — that is an environment problem, not a code problem. The `AckHandleTest`
and `Convert`/`Adapter` groups need no broker.

Benchmarks (M4, before and after the Convert change):

```bash
cabal bench shibuya-kafka-adapter-bench
```

Format before every commit (the pre-commit hook rejects unformatted files; if it
auto-formats, re-stage and commit again):

```bash
nix fmt
git add <files>
git commit
```

Commit convention: commits are made **in the adapter repository**, one per coherent step,
using Conventional Commits (`fix(ack): ...`, `feat(retry): ...`, `test(shutdown): ...`,
`docs(readme): ...`). Every commit body carries these two trailers, whose paths are
relative to the **core repository** (this is the convention: plan documents live in the
core repo even when the work happens elsewhere):

```text
MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery.md
```

Suggested commit sequence (adjust as reality dictates, keep Progress in sync):

```text
fix(shutdown): tolerate RdKafkaRespErrNoOffset and end poll loop on shutdown flag   (M1)
test(shutdown): idle-topic graceful shutdown integration test                        (M1)
feat(retry): seek-based redelivery for AckRetry with per-partition seek barrier     (M2)
test(retry): AckRetry redelivery and handler-exception redelivery integration tests (M2)
fix(ack): classify ack-path Kafka errors; bounded retry; halt hardening             (M3)
test(ack): mock-interpreter unit tests for ack-path classification                  (M3)
feat(deadletter): loud interim dead-letter policy; attempt limitation documented    (M4)
refactor(config)!: remove dead offsetReset; verify topics against subscription      (M4)
docs: Serial-only contract, halt/eviction lifecycle, shutdown ordering, rebalance   (M4)
perf(convert): compute headersToList once                                           (M4)
```

Progress updates to this plan file are committed **in the core repository** with ordinary
`docs(plans): ...` messages.


## Validation and Acceptance

The plan is done when all of the following hold, each observable by running a command:

1. **Idle shutdown is prompt and clean.** With the broker up, the new idle-topic test
   passes: the adapter source over an empty topic ends within a few poll timeouts of
   `shutdown`, and no `RdKafkaRespErrNoOffset` (or any other error) surfaces. Before M1
   this exact scenario hangs until its timeout and then errors.

2. **AckRetry means redelivery, never loss.** Integration Test A shows the retried message
   delivered at least twice and, in the abandoned-session variant, shows a fresh consumer
   in the same group receiving the failed message again — proving the committed offset
   never passed it. Reverting `mkAckHandle`'s retry arm to `storeOffsetMessage` makes this
   test fail.

3. **Handler exceptions cannot skip a message.** Integration Test B (full `runApp`, handler
   throws once on a designated message) shows that message eventually processed. This test
   is green once the sibling core checkout contains EP-23; until then it is explicitly
   marked pending with EP-23 named in the code.

4. **Ack-path errors are classified, and halt survives a failing pause.** The
   `AckHandleTest` unit group passes without a broker: bounded retry counts observed,
   `fatalError` set on persistent failure, `finalize` never throws, `AckHalt` with a
   failing pause still returns normally.

5. **Dead letters are loud and documented.** Running Test A's dead-letter variant (finalize
   one message with `AckDeadLetter (PoisonPill "test")`) prints the
   `[shibuya-kafka-adapter] WARNING: dead-lettered message DROPPED` line on stderr and the
   group's committed offset moves past the message; the README and module Haddock carry the
   warning and the `attempt`-is-`Nothing` limitation.

6. **The whole suite and the docs build.** From the adapter repository root, with the
   broker up: `cabal build all`, `cabal test shibuya-kafka-adapter`, `cabal haddock
   shibuya-kafka-adapter`, and `cabal bench shibuya-kafka-adapter-bench` all succeed;
   `nix fmt` produces no diff on the final tree.


## Idempotence and Recovery

Every step is an ordinary source edit plus tests; re-running builds and tests is always
safe. The integration tests are self-isolating — each creates a topic and group under a
fresh random prefix (`test/Kafka/TestEnv.hs`), so re-runs never collide with earlier state;
a polluted broker can always be reset with `just process-down && just process-up` (the
Redpanda container is purged on down). If a milestone leaves the tree broken, `git stash`
or reset in the adapter repository loses nothing but that milestone's edits; milestones are
ordered so each commit compiles and passes the suite that exists at that point. The seek
barrier and fatal-slot designs are idempotent by construction (repeated `AckRetry` on the
same message reinstates the same barrier entry; `fatalError` is write-once in effect since
the stream terminates on first observation). The only API break (removing `offsetReset`)
is confined to one commit with a version bump, easy to revert in isolation.


## Interfaces and Dependencies

**Adapter library modules and the signatures that must exist at the end** (all in the
adapter repository under `shibuya-kafka-adapter/src/`):

- `Shibuya.Adapter.Kafka.Internal`: `data KafkaAdapterState` (fields `shutdownVar :: TVar
  Bool`, `seekBarrier :: IORef (Map (TopicName, PartitionId) Offset)`, `fatalError ::
  IORef (Maybe KafkaError)`); `newKafkaAdapterState :: IO KafkaAdapterState`;
  `kafkaSource :: (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterState -> KafkaAdapterConfig -> Stream (Eff es) (Either KafkaError
  (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))` (checks shutdown flag and fatal
  slot inside the poll step); `dropStaleRecords`; `mkAckHandle` and `mkIngested` taking
  `KafkaAdapterState` and `KafkaAdapterConfig`; the internal `ackAttempt` and
  `storeGuarded` helpers.
- `Shibuya.Adapter.Kafka`: `kafkaAdapter :: (KafkaConsumer :> es, Error KafkaError :> es,
  IOE :> es) => KafkaAdapterConfig -> Eff es (Adapter es (Maybe ByteString))` (unchanged
  signature); `kafkaAdapterWith :: (...same constraints...) => KafkaAdapterState ->
  KafkaAdapterConfig -> Eff es (Adapter es (Maybe ByteString))`; re-export
  `KafkaAdapterState`, `newKafkaAdapterState`; `kafkaRebalanceHandler ::
  KafkaAdapterState -> Kafka.Consumer.KafkaConsumer -> RebalanceEvent -> IO ()`; the
  `OffsetReset` re-export is dropped along with the config field.
- `Shibuya.Adapter.Kafka.Config`: `KafkaAdapterConfig` with exactly `topics`,
  `pollTimeout`, `batchSize`; `defaultConfig :: [TopicName] -> KafkaAdapterConfig`.
- `Shibuya.Adapter.Kafka.Convert`: existing exports plus `extractTraceHeadersFromList`.

**Dependencies used and why** (all already in the cabal file; no new dependencies):
`kafka-effectful` (`Kafka.Effectful.Consumer.Effect`) for every consumer operation —
including `seekPartitions :: [TopicPartition] -> Timeout -> Eff es ()`, verified present,
so no upstream work; `hw-kafka-client` for `TopicPartition (..)`, `PartitionOffset (..)`,
`RdKafkaRespErrT (..)`, `RebalanceEvent (..)`, and the `setCallback`/`rebalanceCallback`
properties combinators (re-exported by `Kafka.Effectful.Consumer`); `hw-kafka-streamly`
for `skipNonFatal` and the `isFatal` predicate reused as the transient/persistent
classifier; `containers` for the barrier map; `effectful-core` for `catchError`/
`throwError` and dynamic-dispatch interpretation in the mock tests; `stm` for the shutdown
`TVar`.

**Core contracts this plan consumes (soft dependencies, both in the core repository).**
EP-23 (`docs/plans/23-*.md` once present; contract recorded in the master plan's Decision
Log): on a handler exception, core's single-message path finalizes with `AckRetry
(RetryDelay 0)` — which is precisely why this adapter's `AckRetry` arm must not store, and
why integration Test B is gated on the core pin including EP-23. EP-23 also owns the
`AckHandle` idempotency wording (finalize called at most once per message on the
single-message path; possibly multiple times on the batch path) — the barrier/`ackAttempt`
design satisfies it because every finalize action here is idempotent (re-storing the same
offset, re-seeking to the same offset, and re-pausing are all no-ops at the broker). EP-24
owns `validatePolicy` in `shibuya-core/src/Shibuya/Policy.hs`, whose rejection of
`PartitionedInOrder` + `Async` the Serial-only documentation cites. If EP-23 ships as a
new shibuya-core version, bump the `shibuya-core` bound in the adapter cabal file in this
plan's final commit and note the version here.

Revision note, 2026-07-02: M1 implementation began. Progress now records the shutdown fixes, the idle-shutdown integration test addition, the required `shibuya-core` 0.8 bound migration, and validation evidence from the Nix dev shell; live broker validation remains pending because no Redpanda broker was listening on `localhost:9092`.

Revision note, 2026-07-02: M2 implementation added `KafkaAdapterState`, seek-based `AckRetry`, guarded stores, stale-record filtering, and three broker-backed redelivery tests. The test target compiles and broker-free groups pass; live Redpanda validation remains pending.
