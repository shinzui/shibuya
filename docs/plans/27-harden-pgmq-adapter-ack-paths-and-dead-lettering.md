---
id: 27
slug: harden-pgmq-adapter-ack-paths-and-dead-lettering
title: "Harden PGMQ adapter ack paths and dead-lettering"
kind: exec-plan
created_at: 2026-07-02T03:49:03Z
master_plan: "docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md"
---

# Harden PGMQ adapter ack paths and dead-lettering

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a child of the MasterPlan at `docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md` (EP-27). It has a soft, contractual dependency on EP-23 (`docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md`): EP-23 owns the `AckHandle` idempotency contract, whose agreed wording is "the framework calls `finalize` at most once per message on the single-message path and may call it multiple times on the batch path via bounded retry after transient failure; adapters must make each finalize action idempotent or internally phase-tracked." This plan proceeds on that wording; do not wait for EP-23's code.

Repository convention. This plan document lives in the shibuya core repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`), but every code change it directs happens in the PGMQ adapter repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`). Each step below states which repository it touches. Commits made in the adapter repository still carry both trailers, with paths relative to the core repository:

```text
MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/27-harden-pgmq-adapter-ack-paths-and-dead-lettering.md
```

Commit messages follow the Conventional Commits specification (`feat:`, `fix:`, `test:`, `docs:`, with `!` for breaking changes), as everywhere in this project.


## Purpose / Big Picture

The PGMQ adapter connects the Shibuya queue-processing framework to pgmq, a message queue implemented inside PostgreSQL. Today the adapter's acknowledgment ("ack") paths — the database operations that run after a handler decides what to do with a message — are fragile in ways that violate at-least-once delivery and can crash a running processor:

- Dead-lettering a message performs two separate database round-trips (insert into the dead-letter queue, then delete from the source queue) with no transaction. A crash between them either duplicates the message into the DLQ on retry or leaves it in both queues.
- A transient database error during any ack (`AckOk` delete, `AckRetry` set_vt, dead-letter, archive) is never retried, even though the *polling* path already has a careful bounded-retry loop. A failed `AckOk` delete silently guarantees duplicate processing.
- The automatic dead-lettering that happens *inside the source stream* (when a message exceeds `maxRetries`) has zero error handling: one transient DB blip crashes the ingester and takes the processor child down with it.
- The `AckHalt` path hardcodes a 3600-second visibility timeout with a comment that mis-describes what it does.
- The publicly documented "concurrent prefetching" feature deadlocks (a known STM deadlock between streamly's `parBuffered` and effectful's unlifting) — the project's own example disables it with a warning while the README recommends enabling it.
- The configuration accepts nonsense values (`batchSize = 0`, `pollInterval = 0` busy-loop, negative timeouts) without complaint, and lease extension can silently *shorten* a message's lease.

After this plan, a user of `shibuya-pgmq-adapter` gets: atomic, idempotent dead-lettering (a property test proves no failure scenario yields a DLQ copy alongside a surviving source row, or duplicate DLQ copies); bounded transient-error retry on every ack path; a processor that survives DB blips during auto-dead-lettering; a configurable halt visibility timeout; config validation with clear errors; a lease extension that never shortens a lease; honest documentation (prefetch removed, `read_ct` semantics explained, pool sizing guidance); and optionally batched acknowledgments for the core batch path. You can see it working by running the adapter test suite (`just test` in the adapter repository), which spins up an ephemeral PostgreSQL, and by the new chaos and property tests that fail against the current code and pass after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here, even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] 2026-07-02: M1: Added `PgmqAdapterEnv` (pool + hooks) and threaded it into `pgmqAdapter`, `mkAckHandle`, and `mkIngested`.
- [x] 2026-07-02: M1: Implemented transactional dead-letter sessions (`hasql-transaction`, send + delete in one transaction) for `DirectQueue` and `TopicRoute`.
- [x] 2026-07-02: M1: Added a per-message completion phase flag (`IORef Bool`) so a finalizer that already succeeded is a no-op on repeat calls.
- [x] 2026-07-02: M1: Replaced partial `TE.decodeUtf8` with `TE.decodeUtf8Lenient` in `mergeDlqHeaders`; added a non-UTF8 regression test.
- [x] 2026-07-02: M1: Added DB-backed chaos tests for double-finalize `AckDeadLetter` idempotency, no duplicate DLQ row after success, and double `AckOk` idempotency.
- [x] 2026-07-02: M2: Factored `retryingTransient` out of the polling path and reused it for ack paths and lease extension.
- [x] 2026-07-02: M2: Auto-DLQ in `mkIngested` now catches exhausted/permanent ack failures, reports via `onAckFailure`, and keeps the source stream alive.
- [x] 2026-07-02: M2: Added `onAutoDeadLetter` and `onAckFailure` hooks on `PgmqAdapterEnv`.
- [x] 2026-07-02: M2: Validation coverage is DB-backed and direct-finalizer focused rather than a new stub-interpreter matrix; `just test` passes with 146 examples.
- [x] 2026-07-02: M3: Added `haltVisibilityTimeout` to config (fallback: `visibilityTimeout`), fixed the `AckHalt` comment, and added a DB-backed `AckHalt` visibility test.
- [x] 2026-07-02: M3: Added `validateConfig` and `PgmqConfigError`; `pgmqAdapter` now returns `Either PgmqConfigError (Adapter es Value)`; validation unit tests cover accepted defaults and rejection rules.
- [x] 2026-07-02: M3: Reworked `leaseExtend` to use absolute `set_vt` and last-known-VT tracking so extension calls never shorten the adapter's tracked lease deadline.
- [x] 2026-07-02: M3: Moved shutdown gating to chunk granularity and release already-read undispatched messages with best-effort `set_vt 0`.
- [x] 2026-07-02: M3: Documentation and Haddocks updated for the new env/config surface; release notes document `read_ct`/delivery-counting and ack-path caveats.
- [x] 2026-07-02: M4: Removed prefetch from the public API (config field, exports, and `Internal` code paths); `rg -n "refetch|Refetch|prefetch|Prefetch" ...` returns no matches across source, tests, examples, and docs.
- [x] 2026-07-02: M4: Bumped adapter version to 0.9.0.0, updated both changelogs, and generated Haddocks.
- [x] 2026-07-02: M5 (optional): Ack coalescing prototype discarded for this pass; the correctness work already changes the public API and core still exposes only per-message finalizers, so coalescing remains future work.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation. Provide concise evidence.

- 2026-07-02: Running `cabal build all` and `cabal test ...` concurrently after the 0.9.0.0 version bump corrupted/split Cabal's local build plan enough to produce duplicate package instances and a transient `renameFile` failure in `dist-newstyle`. A serial `cabal clean`, then `cabal build all`, then `just test` fixed it. Future validation after package-version bumps should avoid parallel Cabal invocations in the same worktree.
- 2026-07-02: The repository's `just test` recipe was red before implementation because it did not pass `--enable-tests`; updating the recipe to `cabal test shibuya-pgmq-adapter-test --enable-tests` made the documented gate match the verified command.
- 2026-07-02: The optional ack-coalescing milestone was not promoted. The correctness release already introduces a breaking env/config surface and `shibuya-core` still exposes only per-message finalizers; batching behind `AckHandle` remains possible but is separate performance work.
- 2026-07-03: The prefetch deadlock was root-caused after the removal shipped and is **not** a streamly bug. `parBuffered` forks producer workers that must unlift `Eff es`; effectful's default `SeqUnlift` strategy `error`s when its unlift is called off-thread (`seqUnliftIO`, `effectful-core/.../Internal/Monad.hs:214`), killing the producer so the consumer hangs on the channel STM read. Both effectful instances that satisfy `MonadAsync (Eff es)` (`MonadUnliftIO` line 433, `MonadBaseControl IO` line 449) read the strategy dynamically, so a scoped `withUnliftStrategy (ConcUnlift Ephemeral Unlimited)` — applied to the concurrent sub-stream via `morphInner` so it does not leak to the non-prefetch path — makes off-thread unlifting legal. The earlier "requires upstream streamly investigation" framing was wrong; the fix is adapter-local. A prototype is planned in the adapter repo (`docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md`).


## Decision Log

Record every decision made while working on the plan.

- Decision: Prefetch is removed from the public configuration entirely (config field `prefetchConfig`, type `PrefetchConfig`, `defaultPrefetchConfig`, and the `pgmqSourceWithPrefetch` / `pgmqChunksPrefetch` / `pgmqMessagesPrefetch` internals), not gated behind an experimental flag.
  Rationale: The feature deadlocks (streamly `parBuffered` + effectful unlifting, see Context), the example app already disables it with a warning, and a flag would keep dead, dangerous code alive. Removal keeps the code path cleanly deletable; reproduction notes are preserved in this plan's Context for future upstream investigation. Pre-made decision from the MasterPlan (2026-07-02).
  Date: 2026-07-02

- Decision: The prefetch removal stands for the 0.9.0.0 release, but the "fix requires upstream streamly investigation" rationale is superseded — the deadlock is an effectful `SeqUnlift` off-thread-unlift error, fixable adapter-locally with scoped `ConcUnlift` (see the 2026-07-03 Surprises entry and the reworded Context reproduction notes). Re-enabling prefetch on that basis is deliberately deferred to a separate, evidence-gated prototype in the adapter repository (`docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md`) rather than reopened inside this plan.
  Rationale: This plan's release scope (correctness hardening + removing a footgun) is complete and shipped as 0.9.0.0; resurrecting a feature belongs in its own plan with its own deadlock-reproduction acceptance test, so the correctness release is not held open on a performance feature. Keeping the removal in place until the prototype passes avoids re-shipping a known-deadlocking API on an unproven fix.
  Date: 2026-07-03

- Decision: `AckDeadLetter` runs the DLQ send and the source delete in a single PostgreSQL transaction, and the finalizer is additionally phase-tracked with an `IORef` so a finalize that already reported success is a no-op if called again.
  Rationale: Two pool sessions with no transaction is the confirmed atomicity hole. hasql sessions compose but are not transactional by themselves; `hasql-transaction` (already in the package set — pgmq-hasql itself depends on `hasql-transaction ^>=1.2`) provides real BEGIN/COMMIT/ROLLBACK. The phase flag satisfies the EP-23 contract that finalize may be called multiple times on the batch path. Pre-made decision.
  Date: 2026-07-02

- Decision: All single-message ack operations (delete, set_vt, archive, the DLQ transaction, lease extension) are wrapped in the same bounded transient-retry classification the poll path uses, factored into a shared helper.
  Rationale: An `AckOk` whose delete fails currently guarantees duplicate processing after VT expiry with zero retry attempts, while polls get five. Same failure class, same policy. Pre-made decision.
  Date: 2026-07-02

- Decision: When auto-dead-lettering inside the source stream exhausts its transient retries (or hits a permanent error), the adapter skips the message — leaving it invisible until its visibility timeout expires, after which pgmq redelivers it — and reports the failure via the `onAckFailure` hook, instead of letting the error propagate and crash the ingester.
  Rationale: The message is safe: it is still in the source queue and VT redelivery will re-trigger auto-DLQ on a later read. Crashing the ingester (current behavior) kills the linked processor child over a recoverable condition. Pre-made decision on direction; the skip-and-report mechanism is fixed here.
  Date: 2026-07-02

- Decision: `AckHalt` uses a new `haltVisibilityTimeout :: Maybe Int32` config field; `Nothing` (the default) falls back to the regular `visibilityTimeout`.
  Rationale: 3600 seconds was an arbitrary hardcode with a misleading comment. Falling back to `visibilityTimeout` gives one fewer knob for the common case while allowing operators who halt for long maintenance windows to park messages longer. Pre-made decision.
  Date: 2026-07-02

- Decision: `leaseExtend` implements "extend never shortens": the new visibility deadline is `max(last known VT, now + requested duration)`, applied with pgmq's absolute-timestamp `set_vt` (pgmq 1.10+, exposed as `setVisibilityTimeoutAt` in pgmq-effectful), with the last known VT tracked in an `IORef` seeded from the message's `visibilityTime` at read.
  Rationale: pgmq's offset `set_vt(queue, id, seconds)` sets `vt := now() + seconds` — an *absolute reassignment*, so the current mapping can shorten a lease (e.g., a 5-second extension request while 60 seconds remain cuts the lease to 5 seconds). pgmq offers no read-and-extend primitive, but the absolute variant plus client-side tracking of the last VT we set (both the initial read VT and every `set_vt` result, which returns the updated row) implements monotone extension without extra round-trips. Clock skew between client and server can still under-extend by the skew amount; this is documented rather than solved.
  Date: 2026-07-02

- Decision: Configuration is validated by a new `validateConfig :: PgmqAdapterConfig -> Either PgmqConfigError PgmqAdapterConfig`, called by `pgmqAdapter`, which now returns `Eff es (Either PgmqConfigError (Adapter es Value))`. Rejected: `batchSize <= 0`, `visibilityTimeout <= 0`, `StandardPolling` with `pollInterval <= 0`, `LongPolling` with `maxPollSeconds <= 0` or `pollIntervalMs <= 0`, `maxRetries < 0`, `haltVisibilityTimeout <= 0` (when present), and `pollRetry.maxAttempts < 1`. `maxRetries = 0` remains legal and means "auto-dead-letter every message before it is ever handed to a handler" (pgmq's `read_ct` is already 1 on first delivery, and the auto-DLQ check is `readCount > maxRetries`); this is documented as a drain-the-queue tool, not a normal setting.
  Rationale: `pollInterval = 0` busy-loops against PostgreSQL, `batchSize = 0` polls forever receiving nothing, and `maxRetries = 0` surprising users into zero processing were all reachable silently. Returning `Either` (not throwing) keeps validation failures typed and testable. Pre-made decision on scope; return-type mechanism fixed here.
  Date: 2026-07-02

- Decision: `pgmqAdapter` gains a `PgmqAdapterEnv` first argument — a plain record carrying the hasql connection `Pool` and two optional callbacks, `onAutoDeadLetter` and `onAckFailure` (both `IO ()`-returning, defaulting to no-ops via `mkPgmqAdapterEnv :: Pool -> PgmqAdapterEnv`). This is a breaking API change; the adapter version bumps 0.8.0.0 → 0.9.0.0.
  Rationale: (a) The transactional dead-letter path must run a composed multi-statement session, but the `Pgmq` effect's interpreter (`pgmq-effectful`, `Pgmq/Effectful/Interpreter.hs`) executes *each operation as its own `Pool.use`* — there is no effect-level way to compose statements into one transaction, so the adapter needs the pool itself. The pool is always available at the call site because `runPgmq pool` requires it. (b) The adapter has no logger effect (verified: nothing in `src/` imports any logging), and auto-DLQ'd messages are filtered out of the stream before core ever counts them (`incReceived` happens downstream), so an env-level callback is the minimal honest observability mechanism; callbacks cannot live in `PgmqAdapterConfig` because it derives `Show`/`Eq`.
  Date: 2026-07-02

- Decision: The transactional dead-letter path bypasses the `Pgmq` effect (and therefore `runPgmqTraced` telemetry) for its two statements, using `pgmq-hasql` statements directly under `hasql-transaction`.
  Rationale: Unavoidable given the interpreter-per-operation design noted above; extending `pgmq-effectful` with a transaction escape hatch is a separate library release out of this plan's scope (recorded as possible future work). Errors are mapped back through `Pgmq.Effectful.fromUsageError` so retry classification (`isTransient`) still applies uniformly.
  Date: 2026-07-02

- Decision: Messages already read from pgmq but dropped at shutdown are released with a batch `set_vt` of 0 at the chunk level, best-effort.
  Rationale: The shutdown gate (`takeUntilShutdown`) currently discards messages whose VT keeps ticking, inflating `read_ct` and delaying redelivery. Moving the gate to chunk granularity (before flattening) means the dropped batch is known and can be released in one `batchChangeVisibilityTimeout` call. Messages already flattened into core's inbox are core's responsibility (drain timeout) and out of the adapter's reach — documented as a residual caveat. Release failures are swallowed after bounded retry (shutdown must not fail because of this).
  Date: 2026-07-02

- Decision: The batch-ack milestone (M5) is optional and last, implemented as an opt-in ack-coalescing layer inside the adapter (core's batch path calls per-message `finalize`; there is no adapter-level batch hook in `shibuya-core`), promoted only if the reliability suite stays green and the bench shows fewer round-trips.
  Rationale: Verified in `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`: even on the batch path, core calls each message's finalizer individually (with bounded retry). Coalescing therefore must happen behind the `AckHandle`. It is real machinery (queue, flusher, completion signalling) and must not block the correctness milestones.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result against the original purpose.

EP-27 completed in adapter commit `2998a3f` (`feat(ack)!: harden pgmq finalization paths`). The adapter now exposes `PgmqAdapterEnv`, validates config with `Either PgmqConfigError`, performs DLQ send/delete in one transaction, phase-tracks successful finalizers, retries transient ack operations, uses configurable `AckHalt` visibility, tracks lease extension with absolute pgmq deadlines, releases already-read undispatched chunks on shutdown, removes the deadlocking prefetch/lookahead API, and bumps `shibuya-pgmq-adapter` to 0.9.0.0.

Validation evidence from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`:

```text
cabal build all
... builds shibuya-pgmq-adapter-0.9.0.0, shibuya-pgmq-example, and shibuya-pgmq-adapter-bench successfully

just test
Finished in 34.3082 seconds
146 examples, 0 failures
Test suite shibuya-pgmq-adapter-test: PASS

cabal haddock shibuya-pgmq-adapter
Documentation created: dist-newstyle/.../doc/html/shibuya-pgmq-adapter
```

Haddock still reports non-fatal unresolved-link/re-export warnings (`AckHalt`, `readCount`, generated `Rep_*` names, and missing dependency docs for `postgresql-libpq-configure`/`attoparsec`), but documentation generation succeeds.


## Context and Orientation

Two repositories are involved. The core framework repository is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; it contains this plan and the `shibuya-core` package that defines the framework types (`Adapter`, `AckHandle`, `Ingested`, `Lease`, `AckDecision`). The adapter repository is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`; it is a cabal multi-package project containing the library package `shibuya-pgmq-adapter/` (note: same name as the repo directory — the library sources are at `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/`), a benchmark package `shibuya-pgmq-adapter-bench/`, and an example app `shibuya-pgmq-example/`. All code edits in this plan happen in the adapter repository unless explicitly stated otherwise.

Vocabulary used throughout:

- *pgmq* is a PostgreSQL extension implementing a message queue as tables; each queue is a table `pgmq.q_<name>`. Reading a message sets its *visibility timeout* (VT): a timestamp before which no other reader will receive it. `pgmq.set_vt(queue, msg_id, seconds)` reassigns VT to `now() + seconds`; a pgmq-1.10 overload `set_vt(queue, msg_id, timestamp)` assigns an absolute deadline. `read_ct` is a per-message counter incremented on every *read* (delivery), regardless of whether processing failed.
- *Ack path* means the database operation performed by `AckHandle.finalize` in response to a handler's `AckDecision`: `AckOk` → delete, `AckRetry d` → set_vt(d), `AckDeadLetter` → send-to-DLQ + delete (or archive when no DLQ is configured), `AckHalt` → set_vt.
- *Auto-DLQ* means the adapter dead-lettering a message itself, inside the source stream, when `readCount > maxRetries` — the handler never sees such a message.
- *hasql* is the PostgreSQL client library; a `Hasql.Session.Session` is a monadic sequence of statements executed on one pooled connection, but it is *not* a transaction unless wrapped (the `hasql-transaction` package provides `Hasql.Transaction.Sessions.transaction`, which brackets a `Hasql.Transaction.Transaction` in BEGIN/COMMIT with rollback on failure).
- *effectful* is the effect-system library; `Eff es a` is a computation over effect list `es`. The `Pgmq` effect (from `pgmq-effectful`) exposes pgmq operations; its interpreter `runPgmq pool` (at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs`) runs *every single operation as its own `Pool.use`* — this is why atomic multi-statement work cannot be expressed through the effect and needs the pool directly. Errors surface as `PgmqRuntimeError` through `Effectful.Error.Static`; `Pgmq.Effectful.isTransient :: PgmqRuntimeError -> Bool` classifies acquisition timeouts, networking errors, and connection-level session errors as transient, everything else (auth failures, statement errors) as permanent.

Key adapter files (paths relative to the adapter repository root):

- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` — everything this plan hardens. `mkAckHandle` (lines ~199–291) maps decisions to pgmq calls: `AckOk` → `deleteMessage`; `AckRetry` → `changeVisibilityTimeout`; `AckDeadLetter` (lines ~222–277) → `sendMessage`/`sendMessageWithHeaders`/`sendTopic`/`sendTopicWithHeaders` to the DLQ *then* `deleteMessage` — two separate pool sessions, no transaction, no retry, no idempotency; `AckHalt` (lines ~278–288) hardcodes `vtSeconds = 3600` under the comment "extend VT far into future — Message becomes visible again after processor restarts", which is wrong (nothing ties visibility to a restart; the message simply reappears after 3600 s whether or not anything restarted). `mkIngested` (lines ~347–368) performs auto-DLQ inline in the stream (`readCount > maxRetries` → `ackHandle.finalize (AckDeadLetter MaxRetriesExceeded)`) with no error handling. `pgmqChunks` (lines ~373–432) contains `pollRetrying`, the bounded exponential-backoff retry over `isTransient`-classified errors — applied *only* to polling. `mkLease` (lines ~167–185) maps the core's additive "extend by duration" semantics onto offset `set_vt`, i.e. absolute `now + duration`, which can shorten a lease. `mergeDlqHeaders` (lines ~309–343) calls partial `TE.decodeUtf8` (line ~341), which throws on non-UTF-8 header bytes. Prefetch variants `pgmqChunksPrefetch` / `pgmqMessagesPrefetch` / `pgmqSourceWithPrefetch` (lines ~467–513) wrap the chunk stream in streamly's `parBuffered`.
- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` — public module. `pgmqAdapter` (lines ~198–221) assembles the adapter, selecting the prefetch source when `config.prefetchConfig` is `Just` (lines ~207–214); `takeUntilShutdown` (lines ~224–232) gates the per-message stream on a shutdown `TVar` (dropping already-read messages with their VT ticking).
- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` — `PgmqAdapterConfig` (queueName, `visibilityTimeout :: Int32`, `batchSize :: Int32`, `polling`, `pollRetry :: PollRetryConfig`, `deadLetterConfig`, `maxRetries :: Int64`, `fifoConfig`, `prefetchConfig`), all `deriving stock (Show, Eq, Generic)`, with *no validation anywhere*: `batchSize <= 0`, `pollInterval = 0` (busy-loop), `visibilityTimeout <= 0`, and `maxRetries = 0` (dead-letters on first read) are all accepted silently.
- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` — pure conversions: `pgmqMessageToEnvelope`, `mkDlqPayload` (builds the DLQ message body), `readCountToAttempt`.
- Tests in `shibuya-pgmq-adapter/test/`: `TmpPostgres.hs` (ephemeral PostgreSQL via the `ephemeral-pg` package + pgmq schema via `pgmq-migration`; `withPgmqDb` yields a 10-connection pool, `withTestFixture` creates a unique queue + DLQ pair per test; DB tests can be skipped with `PGMQ_TEST_SKIP_DB=1`), `TestUtils.hs` (send helpers, `runWithPool`), `ChaosSpec.hs` (poison messages, slow handlers, graceful shutdown — against a real ephemeral DB), `IntegrationSpec.hs`, `InternalSpec.hs` (includes `runStubPgmq`, a stub `Pgmq` interpreter used by the existing poll-retry tests — the pattern to extend for ack-retry tests), `ConvertSpec.hs`, `PropertySpec.hs`, `ConfigSpec.hs`. Known coverage gaps this plan fills: no `AckHalt` mapping test, no end-to-end lease-extension test, no adapter-level auto-DLQ test, no prefetch test (moot after removal), and no DB-failure-during-ack test.
- `shibuya-pgmq-example/app/Consumer.hs` line 257: `-- NOTE: prefetch is disabled due to STM deadlock issue with streamly parBuffered` (with `prefetchConfig = Nothing` at line 264) — while `docs/pgmq-adapter/README.md` (lines 24, 141–148, 161), `docs/pgmq-adapter/ARCHITECTURE.md` (Prefetching sections), `docs/user/pgmq-advanced.md`, and the Haddocks on `pgmqAdapter` and `defaultConfig` all advertise/recommend `prefetchConfig = Just defaultPrefetchConfig`.

Prefetch deadlock reproduction notes (for future upstream investigation; kept here as context, not as a living discovery). In the adapter repository, set `prefetchConfig = Just defaultPrefetchConfig` on any consumer config in `shibuya-pgmq-example/app/Consumer.hs` (e.g., `notificationsAdapterConfig`), start PostgreSQL per that repo's `process-compose.yaml`, run `cabal run shibuya-pgmq-simulator` and `cabal run shibuya-pgmq-consumer`: the consumer stops making progress once `parBuffered`'s channel is involved, typically dying with `thread blocked indefinitely in an STM transaction`. The mechanism (confirmed 2026-07-03, superseding the earlier "suspected … upstream streamly" reading): `StreamP.parBuffered` spawns producer worker threads and runs the source stream's steps on them, obtaining an `Eff es a -> IO a` unlift from the base monad's `MonadAsync` instance. For `Eff es` that unlift is governed by effectful's ambient `UnliftStrategy`, which defaults to `SeqUnlift`. `SeqUnlift`'s unlift *throws* the moment it is invoked off its creating thread (`effectful-core/src/Effectful/Internal/Monad.hs`, `seqUnliftIO`, ~line 214: `error "… have a look at UnliftStrategy (ConcUnlift)."`). So the forked producer dies on its first unlift, never produces, and the consumer blocks forever on the channel's STM read — the observed `thread blocked indefinitely in an STM transaction`. This is a property of effectful's default strategy, **not** a streamly bug: streamly 0.12.0 is unchanged in the relevant path and no streamly release fixes it. It is also fixable **without** upstream work — run the concurrent portion under `ConcUnlift` (which clones the effect env per worker thread), scoped locally via `withUnliftStrategy`/`morphInner` so only the prefetch stream is affected. That fix is prototyped in the adapter repository's own follow-up plan, `shibuya-pgmq-adapter/docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md`; the removal decided here stands until that prototype proves the fix on evidence.

Dependency sources on disk (verified with `mori registry`): pgmq-hs at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (packages `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`). Facts verified there that this plan relies on: `Pgmq.Hasql.Sessions` composes in the `Session` monad and exposes batch statements `batchDeleteMessages`, `batchArchiveMessages`, `batchChangeVisibilityTimeout :: BatchVisibilityTimeoutQuery -> Session (Vector Message)` (all `select * from pgmq....` single statements, so each is atomic by itself); the raw `Statement` values are exported from `Pgmq.Hasql.Statements.Message` (e.g. `sendMessage :: Statement SendMessage MessageId`, `deleteMessage :: Statement MessageQuery Bool`, `sendMessageWithHeaders`, `sendTopic`, `sendTopicWithHeaders`), which is what lets us lift them into `hasql-transaction`'s `Transaction` monad; `changeVisibilityTimeout` executes `select * from pgmq.set_vt($1,$2,$3)` and *returns the updated `Message`* (whose `visibilityTime :: UTCTime` field is the new deadline — used by the lease fix); `setVisibilityTimeoutAt :: VisibilityTimeoutAtQuery -> Session Message` is the absolute-timestamp overload (pgmq 1.10+), also exposed through the `Pgmq` effect as `Pgmq.Effectful.Effect.setVisibilityTimeoutAt`; `pgmq-hasql.cabal` depends on `hasql-transaction ^>=1.2`, so that package is available in the nix package set. `Pgmq.Types.Message` carries `messageId`, `visibilityTime`, `enqueuedAt`, `lastReadAt`, `readCount :: Int64`, `body`, `headers`.

Build and test commands for the adapter repository (verified against its `Justfile`; run all of them from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`):

```bash
just build      # = cabal build all
just test       # = cabal test shibuya-pgmq-adapter-test
just bench      # = cabal bench shibuya-pgmq-adapter-bench   (M5 only)
nix fmt         # required before every commit (treefmt pre-commit hook)
```

The test suite needs no external database: `TmpPostgres.hs` starts an ephemeral PostgreSQL itself. The test-suite's `hs-source-dirs` includes `src`, so tests may import `Shibuya.Adapter.Pgmq.Internal` directly. The adapter currently pins `shibuya-core ^>=0.7.0.0` (core is at 0.7.1.0); if EP-23 ships a new core version while this plan is in flight, bump the pin in the final milestone and note the version in the MasterPlan's Integration Points.


## Plan of Work

The work is five milestones. M1 fixes the worst correctness hole (dead-letter atomicity and idempotency) and introduces the one structural change everything else reuses (`PgmqAdapterEnv`). M2 spreads the existing transient-retry discipline to every ack path and makes in-stream auto-DLQ non-fatal. M3 is the configuration and semantics milestone (halt VT, validation, lease monotonicity, shutdown release, caveat docs). M4 removes the broken prefetch feature and makes the documentation truthful, shipping the breaking release. M5 is an optional, explicitly prototype-scoped ack-batching layer. Milestones are ordered so each leaves the repository releasable; M1–M3 are internal hardening (plus the env-argument break), M4 is the public-surface change, M5 is additive.


### Milestone 1 — Atomic, idempotent dead-lettering (adapter repository)

Scope: make `AckDeadLetter` atomic (one transaction) and idempotent (phase-tracked), fix the `decodeUtf8` partiality on the same code path, and prove both properties with tests against the ephemeral database. At the end of this milestone a crash or error at any point of dead-lettering leaves the system in exactly one of two states — message intact in the source queue, or exactly one DLQ copy and no source row — and calling `finalize` twice is harmless.

First, introduce the environment record. In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` (or a new small module `Shibuya.Adapter.Pgmq.Env` if you prefer to keep `Config.hs` pure-data; either is acceptable, but export everything from `Shibuya.Adapter.Pgmq`) add:

```haskell
-- | Runtime environment for the adapter: resources and hooks that are not
-- pure configuration. Deliberately has no Show/Eq instances.
data PgmqAdapterEnv = PgmqAdapterEnv
  { -- | The same pool passed to 'Pgmq.Effectful.runPgmq'. Needed because the
    -- Pgmq effect runs every operation on its own pooled connection, so the
    -- transactional dead-letter path must reach the pool directly.
    pool :: !Pool.Pool,
    -- | Called after a message is auto-dead-lettered by the adapter
    -- (readCount > maxRetries). Such messages never reach the handler or
    -- core metrics; this hook is the only way to observe them.
    onAutoDeadLetter :: Pgmq.Message -> IO (),
    -- | Called when an ack-path operation fails permanently (after bounded
    -- retry) in a context where the adapter swallows the error (auto-DLQ,
    -- shutdown release) instead of propagating it.
    onAckFailure :: Pgmq.Message -> PgmqRuntimeError -> IO ()
  }

mkPgmqAdapterEnv :: Pool.Pool -> PgmqAdapterEnv
mkPgmqAdapterEnv p = PgmqAdapterEnv { pool = p, onAutoDeadLetter = \_ -> pure (), onAckFailure = \_ _ -> pure () }
```

Thread it through: `pgmqAdapter :: ... => PgmqAdapterEnv -> PgmqAdapterConfig -> Eff es (Adapter es Value)` in `Shibuya/Adapter/Pgmq.hs`, and `mkAckHandle` / `mkIngested` in `Internal.hs` take the env alongside the config. Add `hasql-pool` (and `hasql`, `hasql-transaction`) to the library `build-depends` in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` (the test-suite already has `hasql`/`hasql-pool`). Update every call site: all five test specs construct adapters, and `shibuya-pgmq-example/app/Consumer.hs` — they all already have the pool in scope.

Second, the transactional dead-letter session. In `Internal.hs`, replace the `Just dlqConfig` branch of `mkAckHandle`'s `AckDeadLetter` case with a call to a new function:

```haskell
-- | Send the DLQ copy and delete the source row in ONE transaction.
-- Runs directly against the pool (see Decision Log: the Pgmq effect cannot
-- compose statements into a transaction). Errors are rethrown as
-- PgmqRuntimeError so isTransient-based retry classification still applies.
deadLetterTransactionally ::
  (IOE :> es, Error PgmqRuntimeError :> es) =>
  Pool.Pool ->
  PgmqAdapterConfig ->
  DeadLetterConfig ->
  Pgmq.Message ->
  Value ->            -- dlq body (mkDlqPayload result)
  Maybe Value ->      -- merged dlq headers
  Eff es ()
deadLetterTransactionally pool config dlqConfig msg dlqBody dlqHeaders = do
  let tx :: Transaction ()
      tx = do
        case (dlqConfig.dlqTarget, dlqHeaders) of
          (DirectQueue q, Nothing) ->
            void $ Transaction.statement (SendMessage q (MessageBody dlqBody) Nothing) Msg.sendMessage
          (DirectQueue q, Just hs) ->
            void $ Transaction.statement (SendMessageWithHeaders q (MessageBody dlqBody) (Pgmq.MessageHeaders hs) Nothing) Msg.sendMessageWithHeaders
          (TopicRoute rk, Nothing) ->
            void $ Transaction.statement (SendTopic rk (MessageBody dlqBody) Nothing) Msg.sendTopic
          (TopicRoute rk, Just hs) ->
            void $ Transaction.statement (SendTopicWithHeaders rk (MessageBody dlqBody) (Pgmq.MessageHeaders hs) Nothing) Msg.sendTopicWithHeaders
        void $ Transaction.statement (MessageQuery config.queueName msg.messageId) Msg.deleteMessage
  result <- liftIO $ Pool.use pool (Transaction.Sessions.transaction Transaction.Sessions.ReadCommitted Transaction.Sessions.Write tx)
  either (throwError . fromUsageError) pure result
```

(Imports: `Hasql.Transaction qualified as Transaction`, `Hasql.Transaction.Sessions qualified as Transaction.Sessions`, `Pgmq.Hasql.Statements.Message qualified as Msg`, `Pgmq.Effectful (fromUsageError)`. Field names/record syntax must match `Pgmq.Hasql.Statements.Types` exactly — use record construction as the current code does; the positional form above is illustrative. Check the `MessageBody` wrapping against `Convert.mkDlqPayload`'s current return type and keep whatever it already produces.) The no-DLQ branch (`archiveMessage`) stays a single statement through the `Pgmq` effect — a single statement is already atomic. Note `mkAckHandle` now needs `Error PgmqRuntimeError :> es` in its constraints; that effect is always present where the handle runs (the source stream already requires it), so this changes signatures, not effect stacks.

Third, phase tracking. Give `mkAckHandle` an `IORef Bool` ("already finalized successfully"), created in `mkIngested` per message (this makes `mkIngested`'s construction of the handle `Eff`-monadic — it already is). `finalize` reads the flag first: if `True`, return `()` immediately; on any successful completion of the decision's action, set it to `True` before returning. A finalize that *fails* leaves the flag `False` so the batch path's bounded retry can genuinely retry. This exactly implements the EP-23 contract wording quoted at the top of this plan. Document on the handle construction that a transaction whose COMMIT succeeded but whose result was lost to a connection drop is reported as a (transient) failure and will be retried, in which case the retry's `sendMessage` inserts a second DLQ copy while `deleteMessage` affects zero rows — this ambiguous-commit window is inherent to any non-idempotent SQL over at-least-once retry and is why the window is now a single small transaction rather than two sessions; state it in the Haddock as the residual (rare) duplication mode.

Fourth, the one-line safety fix on the same path: in `mergeDlqHeaders` (line ~341), replace both uses of `TE.decodeUtf8` with `TE.decodeUtf8Lenient` (`Data.Text.Encoding.decodeUtf8Lenient`, available in text ^>=2.1) so a non-UTF-8 trace-header byte sequence produces replacement characters instead of an exception inside the finalizer.

Fifth, tests (in the adapter repository, `shibuya-pgmq-adapter/test/`):

- Extend `ChaosSpec.hs` with a "DLQ atomicity" group. Test A (atomicity under send failure): create the fixture, then *drop the DLQ queue* before finalizing, so the transaction's send statement fails (a permanent statement error). Read a message via the adapter machinery (or construct the handle directly with `mkIngested`), call `finalize (AckDeadLetter (PoisonPill "x"))`, assert it throws/returns the error, then assert the source queue still contains the message (visible after VT or via direct SQL count) and the DLQ (recreated) has zero rows — under the old two-session code the equivalent failure ordering leaks state; under the transaction it cannot. Test B (idempotency): finalize the same handle twice with `AckDeadLetter`; assert exactly one DLQ row and an empty source queue, second call a no-op. Test C (double `AckOk`): finalize `AckOk` twice; no error, message deleted once.
- Extend `PropertySpec.hs` (or a new `DlqTransactionSpec.hs`) with the conservation property: for a generated sequence of finalize calls and injected failures (using the stub-interpreter approach from `InternalSpec.runStubPgmq` extended to record `SendMessage`/`DeleteMessage`/`ArchiveMessage` operations and inject scripted errors), in no scenario does the recorded operation log imply "DLQ copy exists AND source row survives" or "two DLQ copies from one handle whose first attempt reported success". For the real-DB variant, a smaller hspec property over N messages with a randomly failing first finalize (via the dropped-queue trick) suffices.
- Unit test for `mergeDlqHeaders` with invalid UTF-8 bytes (e.g. `"\xff\xfe"`) asserting no exception and replacement-character output.

Acceptance: `just test` passes; the new atomicity test fails when run against the pre-milestone code (verify once by stashing the fix) and passes after. Commit as `feat(ack)!: make dead-lettering transactional and idempotent` (the `!` for the `pgmqAdapter` signature change) with the two plan trailers.


### Milestone 2 — Bounded retry on every ack path; auto-DLQ that cannot crash the ingester (adapter repository)

Scope: factor the poll path's transient-retry loop into a reusable combinator, apply it to all single-message ack operations, and convert in-stream auto-DLQ failures from ingester-fatal to skip-and-report. At the end, a flickering database connection during any acknowledgment gets the same five-attempt exponential backoff a poll gets, and a processor survives a DB blip that happens to land on an auto-dead-lettering read.

In `Internal.hs`, extract from `pgmqChunks.pollRetrying` a standalone:

```haskell
-- | Run an action, retrying transient PgmqRuntimeErrors with bounded
-- exponential backoff. Permanent errors and exhausted budgets rethrow.
retryingTransient ::
  (Error PgmqRuntimeError :> es, IOE :> es) =>
  PollRetryConfig ->
  Eff es a ->
  Eff es a
```

with byte-for-byte the same semantics as today's `pollRetrying` (attempt counter starts at 1, `isTransient` gate, `threadDelay`, doubling backoff capped at `maxBackoff`, rethrow via `throwError`). Rewrite `pollRetrying` as `retryingTransient config.pollRetry poll` and add a config field `ackRetry :: PollRetryConfig` to `PgmqAdapterConfig` (default `defaultPollRetryConfig`; validated in M3) so ack and poll budgets can diverge. Wrap every effectful operation in `mkAckHandle` — the `AckOk` delete, the `AckRetry` set_vt, the archive, the M1 dead-letter transaction, and the `AckHalt` set_vt — in `retryingTransient config.ackRetry`. Wrap `mkLease`'s extension call the same way. After exhausted retries the error still propagates out of `finalize`: on the single-message path core records the failure; on the batch path core's own `finalizeWithRetry` adds its outer bounded retry, which is safe because the handle is phase-tracked (M1).

Auto-DLQ resilience: in `mkIngested`, wrap the `finalize (AckDeadLetter MaxRetriesExceeded)` call in `catchError`. On success, call `liftIO (env.onAutoDeadLetter msg)` and return `Nothing` as today. On error (necessarily post-retry or permanent), call `liftIO (env.onAckFailure msg err)` and return `Nothing` *without rethrowing*: the message stays in the source queue, its VT expires, pgmq redelivers, and the auto-DLQ check fires again on the next read. Document on `mkIngested` that this trades immediate dead-lettering for ingester survival, and that `read_ct` keeps growing across such skips (harmless — the check is `>`).

Tests: extend `InternalSpec.hs`'s stub interpreter (`runStubPgmq`) to script `DeleteMessage` / `ChangeVisibilityTimeout` / `ArchiveMessage` responses with a call counter, then assert: transient-then-success delete is retried and succeeds (counter = failures + 1); permanent delete error is not retried (counter = 1); exhausted budget rethrows. For auto-DLQ: build a config with `maxRetries = 0`, a stub whose `ArchiveMessage` (no-DLQ auto-dead-letter path) fails permanently, drive one message through `pgmqSource`, and assert the stream yields no `Ingested`, does *not* error, and the `onAckFailure` hook fired once. Add an adapter-level auto-DLQ integration test in `IntegrationSpec.hs` (currently missing): real DB, `maxRetries = 1`, DLQ configured, a handler that always returns `AckRetry (RetryDelay 0)`; assert the message ends up in the DLQ with the `MaxRetriesExceeded` reason in its payload (via `Convert.mkDlqPayload`'s `dead_letter_reason` key), the source queue is empty, and `onAutoDeadLetter` fired.

Acceptance: `just test` green; the stub-based tests fail on pre-milestone code. Commits: `feat(ack): bounded transient retry for all ack paths` and `fix(source): auto-DLQ failures no longer crash the ingester`, both with trailers.


### Milestone 3 — Configuration honesty: halt VT, validation, monotone leases, shutdown release, caveat docs (adapter repository)

Scope: every configuration surprise found in review gets either a validation error or defined, documented semantics. At the end, `pgmqAdapter` rejects nonsense configs with a typed error; `AckHalt` parks messages for a configured, documented duration; `leaseExtend` can only lengthen a lease; shutdown releases what it can; and `read_ct`'s true meaning is documented where users will read it.

Halt VT: add `haltVisibilityTimeout :: !(Maybe Int32)` to `PgmqAdapterConfig` (default `Nothing` in `defaultConfig`). In `mkAckHandle`'s `AckHalt` branch use `fromMaybe config.visibilityTimeout config.haltVisibilityTimeout` and replace the wrong comment with: the message is parked by reassigning its visibility timeout; it becomes visible to *any* consumer after that many seconds, independent of whether the halted processor restarted; configure `haltVisibilityTimeout` to cover expected operator response time.

Validation: new `PgmqConfigError` sum type (one constructor per rule, each carrying the offending value; `Show`, `Eq`) and `validateConfig :: PgmqAdapterConfig -> Either PgmqConfigError PgmqAdapterConfig` in `Config.hs`, enforcing exactly the rules in the Decision Log entry (batchSize ≥ 1, visibilityTimeout ≥ 1, StandardPolling pollInterval > 0, LongPolling fields ≥ 1, maxRetries ≥ 0, haltVisibilityTimeout ≥ 1 when present, `pollRetry`/`ackRetry` maxAttempts ≥ 1 and backoffs ≥ 0). `pgmqAdapter` becomes `... -> Eff es (Either PgmqConfigError (Adapter es Value))`, short-circuiting on `Left`. Update all call sites (tests, example) to pattern-match. Document `maxRetries = 0` semantics ("auto-dead-letters every message before processing; a queue-drain tool") on the field's Haddock.

Lease monotonicity: change `mkLease` to take the whole `Pgmq.Message` (it needs `visibilityTime`), create `lastVtRef :: IORef UTCTime` seeded with `msg.visibilityTime`, and implement `leaseExtend duration` as: `now <- liftIO getCurrentTime`; `lastVt <- readIORef`; `let target = max lastVt (addUTCTime duration now)`; call `setVisibilityTimeoutAt (VisibilityTimeoutAtQuery config.queueName msgId target)` (through the `Pgmq` effect — it exists there; wrap in `retryingTransient`), and write the returned `Message`'s `visibilityTime` back to the ref. Haddock: extension is monotone ("extend never shortens"); accuracy is bounded by client/server clock skew; concurrent extensions on the same lease are last-write-wins on the ref but still monotone at the database because both compute `max` against an already-set floor.

Shutdown release: in `Shibuya/Adapter/Pgmq.hs`, restructure the shutdown gate to chunk granularity. Today `takeUntilShutdown` wraps the flattened per-message stream; instead, insert the gate between `pgmqChunks` and the flatten/`mkIngested` stages (this means `pgmqSource` takes the shutdown `TVar`, or `pgmqAdapter` composes the pipeline from the chunk stream itself — prefer the latter to keep `Internal` signatures simple): a `Stream.mapM` step checks the `TVar`; when shutdown is set and the chunk is non-empty, release the whole chunk with `batchChangeVisibilityTimeout (BatchVisibilityTimeoutQuery config.queueName msgIds 0)` under `retryingTransient`, swallow any final error via `env.onAckFailure` per message (shutdown must proceed), and end the stream. Document the residual gap: messages already flattened into core's bounded inbox are drained (or dropped) by core's `drainTimeout`, beyond the adapter's reach, and count as deliveries in `read_ct`.

`read_ct` caveat documentation: `read_ct` counts *deliveries*, not *handler failures*. A slow handler whose VT expires mid-processing, a prefetch buffer (historical), a shutdown that drops read messages, or an auto-DLQ skip (M2) all increment it without any handler failure — so `maxRetries` is really "max deliveries before dead-lettering", and aggressive VTs under slow handlers can dead-letter messages that never failed. State this (a) prominently in `docs/pgmq-adapter/README.md` under Retry Handling, (b) on the `maxRetries` field Haddock in `Config.hs`, (c) in the module Haddock of `Shibuya/Adapter/Pgmq.hs` (its "Retry Handling" section).

Tests: `ConfigSpec.hs` gains a `validateConfig` group (each rejection rule, one accepted default config, `maxRetries = 0` accepted). `InternalSpec.hs` gains the `AckHalt` mapping test via the stub: finalize `AckHalt` with `haltVisibilityTimeout = Just 120` asserts a `ChangeVisibilityTimeout` with offset 120; with `Nothing` asserts the offset equals `visibilityTimeout`. `IntegrationSpec.hs` gains the end-to-end lease test: send a message, read it through the adapter source with `visibilityTimeout = 30`, call `lease.leaseExtend 60`, and read the row's `vt` directly (`select vt from pgmq.q_<queue> where msg_id = ...` via a raw hasql session in `TestUtils`) asserting it moved to ≈ now+60; then call `leaseExtend 1` and assert `vt` did *not* decrease — this is the never-shortens behavior and fails against the old offset-based code. A shutdown-release test: fill a queue, `batchSize = 10`, a handler that blocks; trigger `adapter.shutdown`; assert the un-dispatched messages' `vt` returns to ≤ now (visible) well before the original VT would have expired.

Acceptance: `just test` green; lease test demonstrably fails pre-milestone. Commits: `feat(config)!: validate adapter configuration and add haltVisibilityTimeout`, `fix(lease): lease extension never shortens the visibility deadline`, `feat(shutdown): release undispatched messages on shutdown`, `docs: document read_ct delivery-counting semantics` — with trailers.


### Milestone 4 — Remove prefetch; documentation truth pass; release 0.9.0.0 (adapter repository)

Scope: delete the known-deadlocking prefetch feature from the public surface and the internals, align every document with the shipped behavior, and cut the breaking release that carries M1–M4.

Code removal: delete `prefetchConfig` from `PgmqAdapterConfig` and `defaultConfig`; delete `PrefetchConfig` and `defaultPrefetchConfig` from `Config.hs` and the export lists of `Shibuya.Adapter.Pgmq` (lines ~83, ~93) and `Config.hs`; in `Internal.hs` delete `pgmqSourceWithPrefetch`, `pgmqChunksPrefetch`, `pgmqMessagesPrefetch` and their exports; in `Shibuya/Adapter/Pgmq.hs` delete the prefetch branch of the source selection (lines ~207–214, keeping the plain `pgmqSource` path) and the now-unused `StreamP` import; drop the `PrefetchConfig` references from `ConfigSpec.hs` (`defaultPrefetchConfigSpec`) and the `prefetchConfig = Nothing` fields in every test config and in `shibuya-pgmq-example/app/Consumer.hs` (also delete the line-257 NOTE — it is no longer possible to enable). Grep to confirm zero remaining references:

```bash
grep -rn "refetch" shibuya-pgmq-adapter/src shibuya-pgmq-adapter/test shibuya-pgmq-example docs README.md
```

Documentation truth pass (same repository): `docs/pgmq-adapter/README.md` — remove overview item 7, the "With Concurrent Prefetching" section (lines ~141–148), and the Concurrent Prefetch feature-table row; add a short "Removed features" note stating prefetch was removed in 0.9.0.0 because of a deadlock in streamly's `parBuffered` under effectful, with a pointer to this plan's reproduction notes. `docs/pgmq-adapter/ARCHITECTURE.md` — remove the Prefetching layer/sections and diagram mention. `docs/user/pgmq-advanced.md` — remove the Concurrent Prefetching and Prefetch Buffer sections. `docs/user/pgmq-getting-started.md` — remove the commented `prefetchConfig` line. While in the README, add the pool-sizing guidance (also required by M5's doc item, write it now): every in-flight finalize, lease extension, and poll takes a pool connection; with core concurrency `Async n` size the pool at least `n + 2` (n concurrent finalizes + one poller + one lease extension), and remember `Pool.acquire` in `TmpPostgres.hs` uses 10 as a reference point. Also update this same README's ack-path description to mention transactional dead-lettering and ack retry (M1/M2), the `haltVisibilityTimeout` field, validation, and the `PgmqAdapterEnv` argument with a corrected Quick Start snippet.

Release mechanics: bump `version:` in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` to 0.9.0.0; write `CHANGELOG.md` entries for every user-visible change in M1–M4 (breaking: `pgmqAdapter` signature, `Either` return, removed prefetch, new config fields); check the `shibuya-core` pin against what EP-23 shipped (bump if a new core version exists and note it in the MasterPlan's Integration Points section).

Acceptance: `just build` and `just test` green; the grep above returns nothing; `cabal haddock shibuya-pgmq-adapter` builds without warnings about missing docs on the new public items. Commits: `feat!: remove broken prefetch support` and `docs: align adapter docs with 0.9.0.0 behavior` and `chore(release): 0.9.0.0`, with trailers.


### Milestone 5 (optional, prototype) — Batched acknowledgments for the core batch path (adapter repository)

Scope: a prototype ack-coalescing layer that turns N per-message ack round-trips into grouped statements using pgmq-hs batch operations (`batchDeleteMessages`, `batchArchiveMessages`, `batchChangeVisibilityTimeout` — all verified in `Pgmq.Hasql.Sessions`). This milestone is explicitly *prototyping*: build it additively behind an opt-in config, measure, then promote or discard.

Background you must not assume away: shibuya-core's batch path (`shibuya-core/src/Shibuya/Runner/BatchProcessor.hs` in the core repository) calls each retained message's `finalize` *individually*, with its own bounded retry — there is no adapter-visible batch hook. Coalescing therefore lives behind `AckHandle`: an `AckBatcher` created per adapter holding a bounded STM queue of `(operation, messageId, resultVar :: MVar (Either PgmqRuntimeError ()))`; `finalize` classifies its decision (delete / archive / set_vt-with-delay; dead-letter transactions are *never* coalesced — they stay on the M1 path), enqueues, and blocks on its `resultVar`, so per-message exactly-once semantics and phase tracking are preserved. A flusher thread (started by `pgmqAdapter`, stopped by `shutdown` after draining) collects up to `maxBatch` entries or whatever arrived within `maxLinger` (e.g. 5 ms), groups by operation (set_vt additionally by delay value), executes each group as one session under `retryingTransient`, and completes every `resultVar` with the group's outcome. Opt-in via `ackBatching :: Maybe AckBatchingConfig` (`maxBatch :: Int`, `maxLinger :: NominalDiffTime`; validated in `validateConfig`). Update the README's pool-sizing note: with coalescing, concurrent finalizes multiplex onto the flusher's single connection, so pool pressure drops from `n` to ~2.

Promotion criteria: the full test suite (including M1's atomicity/idempotency and M2's retry tests, run with `ackBatching` enabled via a test matrix flag) stays green; `just bench` shows fewer round-trips / higher ack throughput at `batchSize >= 10`; and shutdown under load loses no acks (a test: fill queue, process with coalescing, shutdown mid-stream, assert every `AckOk`'d message is actually deleted). If criteria are not met, delete the module and the config field, and record the measurements in Surprises & Discoveries — the milestone is then complete as "discarded with evidence".

Acceptance if promoted: `just test` green with and without `ackBatching`; bench delta recorded in this plan. Commit: `feat(ack): opt-in ack coalescing using pgmq batch statements`, with trailers.


## Concrete Steps

All commands run from the adapter repository root, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`, unless stated otherwise. Plan-document updates (Progress, Decision Log, etc.) are edited in the core repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/plans/27-harden-pgmq-adapter-ack-paths-and-dead-lettering.md` and committed there with `docs(plans): ...` messages.

Before starting, establish a baseline:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
just build
just test
```

Expected: build succeeds; the test suite ends with a summary like

```text
Finished in ... seconds
... examples, 0 failures
Test suite shibuya-pgmq-adapter-test: PASS
```

(If PostgreSQL cannot start in your sandbox, DB-backed specs can be skipped with `PGMQ_TEST_SKIP_DB=1 just test`, but the milestones' acceptance requires the DB tests, so run them unsandboxed.)

Per milestone the loop is: edit the files named in Plan of Work → `just build` → `just test` → `nix fmt` → `git add` the touched files → commit with the conventional message and both trailers, for example:

```bash
git commit -m "feat(ack)!: make dead-lettering transactional and idempotent

Send-to-DLQ and source delete now run in one hasql transaction; the
finalizer is phase-tracked so repeated finalize calls are no-ops.

MasterPlan: docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md
ExecPlan: docs/plans/27-harden-pgmq-adapter-ack-paths-and-dead-lettering.md"
```

To verify a new test actually bites (required once per milestone's headline test):

```bash
git stash            # stash the fix, keep the test
just test            # expect the new test to FAIL
git stash pop
just test            # expect all green
```

After M4, sanity-run the example end-to-end (needs the repo's dev services):

```bash
just process-up      # starts local PostgreSQL per process-compose.yaml
just create-database
cabal run shibuya-pgmq-simulator   # in one terminal
cabal run shibuya-pgmq-consumer    # in another; observe messages processed, no deadlock
just process-down
```

After completing each milestone, update this plan's Progress section (and Decision Log / Surprises if applicable) in the core repository and commit there.


## Validation and Acceptance

Beyond per-milestone acceptance, the plan as a whole is accepted when, in the adapter repository:

1. `just test` passes with the DB-backed suites enabled, including the new groups: DLQ atomicity/idempotency (Chaos), ack-retry and auto-DLQ resilience (Internal, stub-based), adapter-level auto-DLQ (Integration), `AckHalt` mapping (Internal), `validateConfig` (Config), lease end-to-end never-shortens (Integration), shutdown release (Chaos or Integration).
2. The behavior-level claims hold observably: dropping the DLQ queue and dead-lettering leaves the source message intact and no partial state (atomicity); finalizing twice never duplicates effects (idempotency); a stubbed transient delete failure is retried and succeeds (retry); a permanently failing auto-DLQ leaves the stream alive and the hook informed (resilience); extending a lease by 1 second while 30 remain does not move `vt` backwards (monotonicity); an invalid config yields `Left (SomeConstructor ...)` from `pgmqAdapter` instead of a running adapter (validation).
3. `grep -rn "refetch" shibuya-pgmq-adapter/src shibuya-pgmq-adapter/test shibuya-pgmq-example docs README.md` returns nothing, and the example consumer runs against live services without the historical deadlock note being needed.
4. The version is 0.9.0.0 with a CHANGELOG that names every breaking change, and every commit carries both plan trailers.
5. This plan document's Progress checklist is fully checked (M5 either promoted or explicitly discarded with evidence), Surprises & Discoveries reflects reality, and Outcomes & Retrospective is written.


## Idempotence and Recovery

Every step is safe to re-run. Code edits are idempotent by construction (re-applying an edit that already exists is a no-op); `just build` / `just test` / `nix fmt` are pure of side effects outside `dist-newstyle` and formatting. The test databases are ephemeral (created and destroyed per run by `ephemeral-pg`), so failed test runs leave no state; if a run is killed hard, stray `ephemeral-pg` postgres processes can be found with `pgrep -fl postgres` and killed. If a milestone is half-done at a stopping point, split its Progress entry into done/remaining parts rather than leaving it ambiguous. If M1's cabal changes break the build for the example or bench packages, fix call sites before committing — never commit with `just build` red. The breaking API change is confined to one release: if a later milestone forces another signature change before 0.9.0.0 ships, fold it into the same version rather than chaining breaks. To roll back an entire milestone, `git revert` its commits in the adapter repository; no migrations or persistent state are involved anywhere in this plan.


## Interfaces and Dependencies

Libraries used and why (adapter repository, `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`): existing deps `pgmq-core`/`pgmq-effectful`/`pgmq-hasql ^>=0.3` (queue operations and types), `shibuya-core ^>=0.7.0.0` (framework types), `effectful-core`, `streamly`/`streamly-core`, `stm`, `aeson`, `text`, `time`, `vector`. New library deps added in M1: `hasql ^>=1.10` and `hasql-pool ^>=1.4` (the pool type and `Pool.use` for the transactional path; already test deps) and `hasql-transaction ^>=1.2` (BEGIN/COMMIT bracketing; already in the nix package set via pgmq-hasql's own dependency on it).

Signatures that must exist at the end of each milestone (module paths in the adapter library):

- After M1: `Shibuya.Adapter.Pgmq.Config` (or `.Env`) exports `data PgmqAdapterEnv` with fields `pool :: Pool.Pool`, `onAutoDeadLetter :: Pgmq.Message -> IO ()`, `onAckFailure :: Pgmq.Message -> PgmqRuntimeError -> IO ()`, and `mkPgmqAdapterEnv :: Hasql.Pool.Pool -> PgmqAdapterEnv`; `Shibuya.Adapter.Pgmq.pgmqAdapter :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) => PgmqAdapterEnv -> PgmqAdapterConfig -> Eff es (Adapter es Value)`; `Shibuya.Adapter.Pgmq.Internal.mkAckHandle :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) => PgmqAdapterEnv -> PgmqAdapterConfig -> IORef Bool -> Pgmq.Message -> AckHandle es`, with `deadLetterTransactionally` as specified in M1.
- After M2: `Shibuya.Adapter.Pgmq.Internal.retryingTransient :: (Error PgmqRuntimeError :> es, IOE :> es) => PollRetryConfig -> Eff es a -> Eff es a`; `PgmqAdapterConfig` has `ackRetry :: !PollRetryConfig`.
- After M3: `Shibuya.Adapter.Pgmq.Config.validateConfig :: PgmqAdapterConfig -> Either PgmqConfigError PgmqAdapterConfig` and `data PgmqConfigError`; `PgmqAdapterConfig` has `haltVisibilityTimeout :: !(Maybe Int32)`; `pgmqAdapter` returns `Eff es (Either PgmqConfigError (Adapter es Value))`; `mkLease :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) => PgmqAdapterConfig -> Pgmq.Message -> Eff es (Lease es)` (now `Eff`-monadic to allocate the VT-tracking `IORef`).
- After M4: no `Prefetch`-named identifier exists anywhere in the adapter repository; package version 0.9.0.0.
- After M5 (only if promoted): `PgmqAdapterConfig` has `ackBatching :: !(Maybe AckBatchingConfig)`; `data AckBatchingConfig = AckBatchingConfig { maxBatch :: !Int, maxLinger :: !NominalDiffTime }`.

Services: none beyond ephemeral PostgreSQL, which the test harness (`test/TmpPostgres.hs`, `ephemeral-pg` + `pgmq-migration`) manages itself. The example run in Concrete Steps additionally uses the repo's `process-compose.yaml` services via `just process-up`.

---

Revision note (2026-07-02): Initial full authoring of this plan from the skeleton, based on direct source research of the adapter repository, the pgmq-hs libraries (verified session composition, batch statements, absolute `set_vt`, per-operation pool usage in the effect interpreter), the core `AckHandle`/`BatchProcessor` contract, and the MasterPlan's pre-made decisions. Reason: EP-27 kickoff.

Revision note (2026-07-03): Corrected the prefetch-deadlock root cause. Rewrote the Context reproduction notes (the deadlock is effectful's default `SeqUnlift` erroring on off-thread unlift when `parBuffered` forks producer workers — not an upstream streamly bug — with primary-source evidence from `effectful-core/.../Internal/Monad.hs` and `streamly` 0.12.0), added a 2026-07-03 Surprises entry and a Decision Log entry recording that the removal stands for 0.9.0.0 but the fix is adapter-local via scoped `ConcUnlift`, and cross-referenced the new adapter-repo prototype plan `docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md`. No milestone or acceptance change; the shipped 0.9.0.0 outcome is unaffected. Reason: findings from a post-release investigation into whether recent streamly changes fixed the deadlock.
