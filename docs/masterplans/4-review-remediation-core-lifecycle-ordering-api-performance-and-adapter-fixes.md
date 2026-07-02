---
id: 4
slug: review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes
title: "Review remediation: core lifecycle, ordering, API, performance, and adapter fixes"
kind: master-plan
created_at: 2026-07-02T03:48:55Z
---

# Review remediation: core lifecycle, ordering, API, performance, and adapter fixes

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A comprehensive three-repository review (2026-07-01) of shibuya-core, shibuya-pgmq-adapter, and shibuya-kafka-adapter found that while the inner data path of the core framework (STM inbox bridging, batch accumulation, batch ack resolution) is sound, the lifecycle layer has confirmed deadlocks and supervision-semantics bugs, ordering policies are partially decorative, the Kafka adapter's ack model violates at-least-once delivery outside the Serial happy path, and the PGMQ adapter's dead-letter path is neither atomic nor idempotent. The review also produced a pre-1.0 API cleanup list and a set of hot-path performance findings.

After this initiative is complete: a handler returning `AckHalt` no longer deadlocks `waitApp`; `StopAllOnFailure` and `IgnoreFailures` behave as their documentation states; a handler exception finalizes the message with a well-defined decision instead of silently dropping the ack; the batch path propagates consumer failures, respects halt isolation, keeps backpressure bounded, and cannot ack after shutdown; `PartitionedInOrder` is either enforced with partition-keyed dispatch or rejected at validation; the public API surface is trimmed and internals are hidden behind `Shibuya.Internal.*` before any 1.0 release; the per-message metrics contention point is eliminated; the PGMQ adapter dead-letters atomically and retries ack-path failures; and the Kafka adapter no longer silently loses messages on `AckRetry`, handler exceptions, or shutdown.

Scope boundary. Included: all confirmed critical and major findings from the review, plus the API and performance items listed in the child plans. Explicitly excluded: a Kafka lowest-contiguous-offset (gap-tracking) commit layer enabling safe `Async`/`Ahead` concurrency (recorded as future work — this initiative instead enforces the Serial constraint), a Kafka dead-letter-queue producer (deferred milestone, the adapter documents the limitation), fixing the streamly `parBuffered` STM deadlock inside streamly itself (the PGMQ plan removes/deprecates prefetch rather than fixing upstream), and any new feature work unrelated to review findings.

The three repositories involved are `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (core, this repository — all plan documents live here), `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`, and `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. Cross-repository child plans follow the precedent of plans 13–15, which live in this repository but direct work in the adapter repositories.


## Decomposition Strategy

The findings group naturally by functional concern rather than by file. Core correctness splits into two plans because the lifecycle/supervision fixes (EP-22) are small, independently verifiable diffs to child spawning and strategy mapping, while the finalize-on-exception and batch-path work (EP-23) changes ack semantics and the batch scheduler's structure — different blast radii, different tests, and EP-23 builds on the stabilized lifecycle from EP-22. Ordering-policy enforcement (EP-24) is its own plan because it introduces new dispatch machinery (or new validation rejections) with its own property tests, and both adapters' safety stories reference it. The API cleanup (EP-25) must run after the three correctness plans so module moves and type changes don't churn under active bug-fixing. Performance (EP-26) touches the same hot-path files as EP-22/23 and therefore runs after them, but is otherwise independent. Each adapter gets exactly one plan (EP-27, EP-28) because their findings are internally coupled (the Kafka ack model, shutdown, and error-classification fixes all touch the same `AckHandle` construction) but externally independent of each other.

Alternatives considered: a single "fix everything in core" plan was rejected as unwieldy (it would exceed five milestones and mix unrelated verification strategies); splitting the Kafka plan into ack-model and shutdown plans was rejected because both edit `mkAckHandle`/`shutdown` in one small module and would create needless integration overhead; folding performance into the API cleanup was rejected because performance changes need benchmark evidence while API changes need PVP review — different acceptance criteria.

Seven plans is within the two-to-seven bound, so no phase structure is required, but the Dependency Graph section defines two implementation waves for scheduling clarity.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 22 | Fix processor lifecycle and supervision semantics | docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md | None | None | Complete |
| 23 | Fix finalize-on-exception and batch-path reliability | docs/plans/23-fix-finalize-on-exception-and-batch-path-reliability.md | EP-22 | None | Complete |
| 24 | Enforce ordering policies or reject unsupported combinations | docs/plans/24-enforce-ordering-policies-or-reject-unsupported-combinations.md | None | EP-22 | Complete |
| 25 | Pre-1.0 public API cleanup | docs/plans/25-pre-1-0-public-api-cleanup.md | EP-22, EP-23, EP-24 | None | Complete |
| 26 | Reduce per-message hot-path overhead | docs/plans/26-reduce-per-message-hot-path-overhead.md | EP-22, EP-23 | None | Complete |
| 27 | Harden PGMQ adapter ack paths and dead-lettering | docs/plans/27-harden-pgmq-adapter-ack-paths-and-dead-lettering.md | None | EP-23 | Complete |
| 28 | Make Kafka adapter ack model safe for at-least-once delivery | docs/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery.md | None | EP-23, EP-24 | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-22).


## Dependency Graph

Wave 1 runs EP-22, EP-24, and EP-27 in parallel. EP-22 has no dependencies and unblocks the most. EP-24's validation-rejection milestone is independent; only its optional partition-keyed dispatch milestone touches `Shibuya/Runner/Supervised.hs`, which EP-22 also edits — hence the soft dependency (implementers should rebase on EP-22's merged changes if both are in flight). EP-27 lives in the PGMQ repository and shares no code with core plans; its soft dependency on EP-23 is contractual, not code-level: EP-23 finalizes the `AckHandle` idempotency contract that EP-27's dead-letter finalizer must satisfy, so EP-27's idempotency milestone should not be declared complete until the contract wording from EP-23 is settled (the expected wording is already recorded in the Decision Log below, so EP-27 can proceed on that assumption).

Wave 2 runs EP-23 after EP-22 (hard: both restructure `runIngesterAndProcessor` and the child-exit paths in `Shibuya/Runner/Supervised.hs`; EP-23's exception-propagation tests assume EP-22's `finally`-based `doneVar` semantics), then EP-28 (soft on EP-23 because the Kafka skip-and-commit-past scenario is partially caused by core never finalizing on handler exception — EP-28's tests for that scenario assume EP-23's new finalize-with-`AckRetry` behavior; soft on EP-24 because EP-28 documents/enforces Serial-only operation and cites EP-24's validation rejections). EP-26 requires EP-22 and EP-23 to be complete because it rewrites the metrics update sites those plans touch. EP-25 runs last among core plans: it moves modules to `Shibuya.Internal.*` and changes exports, which would conflict with any concurrent core edit.

EP-27 and EP-28 can proceed in parallel with everything (different repositories) subject to the contractual notes above.


## Integration Points

`Shibuya/Runner/Supervised.hs` (core repository) is edited by EP-22 (child spawning, `doneVar`, link, `poll`→`waitCatch`), EP-23 (`processOne` finalize-on-exception), EP-24 (optional keyed dispatch in `processUntilDrained`), and EP-26 (metrics and tracing hot path). EP-22 defines the resulting lifecycle structure; later plans consume it and must not reintroduce exit paths that skip the `finally`-based `doneVar` write.

The `AckHandle` idempotency contract, stated in `shibuya-core/src/Shibuya/Core/AckHandle.hs`, is owned by EP-23. The agreed wording (Decision Log, 2026-07-02): the framework calls `finalize` at most once per message on the single-message path and may call it multiple times on the batch path via bounded retry after transient failure; adapters must therefore make each finalize action idempotent or internally phase-tracked. EP-25 propagates the wording to Haddocks and to the `Handler` documentation; EP-27 (PGMQ dead-letter phase tracking) and EP-28 (Kafka `AckHandle` guard) implement it.

The handler-exception ack decision is owned by EP-23: on a handler exception the single-message path finalizes with `AckRetry (RetryDelay 0)`, matching the existing batch-path behavior in `shibuya-core/src/Shibuya/Runner/BatchProcessor.hs`. EP-28 consumes this: the Kafka adapter's `AckRetry` mapping must not store the offset (otherwise EP-23's fix would convert Kafka message loss from "silent skip" to "explicit commit-past"), which is exactly EP-28's first milestone.

`validatePolicy` in `shibuya-core/src/Shibuya/Policy.hs` is owned by EP-24, which implemented `PartitionedInOrder` + `Ahead`/`Async` for single-message processors via partition-keyed dispatch and kept a batch-specific rejection in `validateAllPolicies`. EP-25 may now relocate or rename `Policy` types if it preserves these semantics. EP-28 should cite the implemented per-partition core behavior for single-message processors and the separate adapter-level Serial-only constraint.

`SupervisionStrategy` and its NQE mapping in `shibuya-core/src/Shibuya/App.hs` are owned by EP-22 (`StopAllOnFailure` → `NQE.IgnoreGraceful`, conditional linking). EP-25 documents the final semantics.

Adapter repositories pin shibuya-core via their `cabal.project`/flake inputs. If EP-23 ships as a new core version, EP-27 and EP-28 should bump their pins in their final milestones and note the version in this section.

The shibuya-core 0.8.0.0 release train is shared by all core plans. EP-22 and EP-23 make behavior fixes without bumping the version; they should add entries under an unreleased `0.8.0.0` heading in `shibuya-core/CHANGELOG.md` as they land. EP-24's Milestone 1 opens that heading if it does not exist yet (its plan already anticipates finding it open). EP-25 finalizes the changelog, sets `version: 0.8.0.0`, and owns the release. No core plan may publish an intermediate release without updating this section. The adapter repositories version independently (EP-27 targets shibuya-pgmq-adapter 0.9.0.0; EP-28 targets shibuya-kafka-adapter 0.8.0.0).

The bounded keyed-scheduler `pendingLimit` is defined by EP-23 as `max 2 (2 * maxConcurrency)`; EP-24's generalized scheduler reuses that definition (its `2 * max 1 n` spelling is numerically identical — both plans note the reuse).


## Progress

- [x] EP-22: `doneVar` set via `finally` on all child exit paths (halt, cancel, failure); `waitApp` no longer deadlocks after `AckHalt`
- [x] EP-22: `StopAllOnFailure` remapped to `NQE.IgnoreGraceful`; graceful child exit no longer kills siblings
- [x] EP-22: `link` made strategy-aware; `IgnoreFailures` isolates processor failures
- [x] EP-22: ingester `poll` race fixed with `waitCatch`; `runWithMetrics` drain deadlock fixed; `runApp` failure path tears down spawned processors
- [x] EP-23: handler exception finalizes with `AckRetry` on the single-message path
- [x] EP-23: batcher consumer exceptions propagate; batch halt isolation enforced; keyed scheduler bounded and bracketed
- [x] EP-23: `AckHandle` idempotency contract finalized and documented
- [x] EP-24: `validatePolicy` accepts implemented `PartitionedInOrder` + concurrent single-message processors; batching processors reject the unsafe combination; `Ahead` documentation corrected
- [x] EP-24: partition-keyed dispatch implemented for the single-message path
- [x] EP-25: runner internals moved under `Shibuya.Internal.*`; `AppHandle`/`Master` opaque
- [x] EP-25: dead API surface removed; `AppConfig` record with validation; umbrella module completed
- [x] EP-26: hot-path metrics moved to atomic counters; per-message STM transactions eliminated
- [x] EP-26: tracing dummy-span CAF, constant-attribute hoisting, `maxThreads` bound
- [x] EP-27: dead-letter send+delete made transactional and retry-safe
- [x] EP-27: ack-path retries; `AckHalt` visibility timeout configurable; config validation; prefetch removed or fixed
- [ ] EP-28: `AckRetry` no longer stores the offset; failed messages are redelivered
- [ ] EP-28: shutdown fixed (no-offset commit tolerated, poll-aware stream termination)
- [ ] EP-28: ack-path Kafka errors classified; Serial-only constraint enforced and documented


## Surprises & Discoveries

Discoveries made while authoring the child plans (2026-07-02), recorded here because they cross plan boundaries:

- `seekPartitions` already exists in kafka-effectful (Effect.hs line 168) over hw-kafka-client — EP-28's reserved "add a seek wrapper" milestone was dropped. EP-28 also determined that a source-side stale-message filter alone is insufficient (core's ingester buffers into the bounded inbox concurrently with finalize), so retries require an ack-side per-partition seek barrier.
- `atomic-primops` is already in the build closure (verified in `dist-newstyle/cache/plan.json`), so EP-26 uses `Data.Atomics.Counter` with no new top-level dependency.
- `shibuya-metrics` is an additional consumer of the surfaces EP-25 touches: it uses `Master`/`getAllMetricsIO` and exports the always-zero `shibuya_messages_dropped_total` Prometheus series that EP-25 deletes. `shibuya-core-bench` imports runner internals. Both are covered in EP-25's compatibility contract.
- pgmq 1.10+ has an absolute-timestamp `set_vt` overload (`setVisibilityTimeoutAt` in pgmq-hasql) returning the updated row, which lets EP-27 implement true "extend never shortens" lease semantics rather than merely documenting the hazard. pgmq-effectful's interpreter runs every operation as its own `Pool.use`, so EP-27's transactional dead-lettering bypasses the effect and uses the pool directly via a new adapter env record.
- The naive "one STM transaction" fix for the batcher's MVar-across-blocking-write issue deadlocks when a tick emits more batches than remaining queue capacity — EP-26 prescribes a state + pending-`Seq` `TVar` with admission control instead.
- `PolicySpec.hs` currently asserts the buggy behavior ("allows Ahead/Async" for `PartitionedInOrder`) and `docs/architecture/CONCURRENCY.md` documents the wrong support matrix — EP-24 fixes both alongside the code.
- EP-24's `shibuya-core` 0.8.0.0 version bump required a coordinated `shibuya-metrics` 0.8.0.0 bump and `shibuya-core ^>=0.8.0.0` dependency bound update; otherwise workspace-level `cabal build all` and even targeted `cabal test shibuya-core-test` could not solve dependencies because Cabal considered `shibuya-metrics` a user goal in the project.
- EP-27's adapter version bump to `shibuya-pgmq-adapter` 0.9.0.0 exposed that parallel Cabal invocations in the same worktree can corrupt or split `dist-newstyle` build plans after a package-version change. A serial `cabal clean`, `cabal build all`, then `just test` produced a clean plan and green validation. Future adapter validation should avoid parallel Cabal commands against the same `dist-newstyle`.
- EP-28 started against a sibling core checkout already at `shibuya-core` 0.8.0.0, so the Kafka adapter, benchmark package, and jitsurei package bounds had to move to `^>=0.8.0.0` before the workspace could solve. The `otel-demo` jitsurei also needed migration from pre-0.8 internal runner modules to the public `runApp`/`mkProcessor`/`waitApp` API.
- EP-28 validation requires the Nix dev shell for native `librdkafka` linkage on this machine. Plain `cabal build all` typechecked the changed adapter modules but failed with `ld: library not found for -lrdkafka`; `nix develop -c cabal build all` completed successfully. Live integration tests still require Redpanda on `localhost:9092`; without it, broker-free tests pass and the Integration group reports connection refused.


## Decision Log

- Decision: Split core correctness fixes into lifecycle (EP-22) and finalize/batch reliability (EP-23) rather than one plan.
  Rationale: EP-22 is a set of small, independently testable diffs with immediate deadlock relief; EP-23 changes ack semantics and batch-scheduler structure and needs EP-22's stabilized exit paths underneath it. Different verification strategies (lifecycle interleaving tests vs. ack-conservation property tests).
  Date: 2026-07-02

- Decision: `StopAllOnFailure` maps to `NQE.IgnoreGraceful` instead of `NQE.KillAll`.
  Rationale: Verified in NQE 0.6.6 source (`Control/Concurrent/NQE/Supervisor.hs`, `processDead`): `KillAll` calls `stopAll` and stops the supervisor even on graceful child exit (`Right ()`), which contradicts both the strategy's documentation and halt isolation. `IgnoreGraceful` kills all on failure and ignores graceful exits — exactly the documented semantics.
  Date: 2026-07-02

- Decision: On a handler exception, the single-message path finalizes the message with `AckRetry (RetryDelay 0)` before recording the failure.
  Rationale: Aligns with the batch path, which already substitutes retry-all on batch-handler exceptions (`BatchProcessor.hs`). Guarantees no message is left un-finalized. Adapters map `AckRetry` to their redelivery mechanism; the Kafka adapter's broken `AckRetry` mapping is fixed in EP-28 before this could make its behavior worse.
  Date: 2026-07-02

- Decision: `AckHandle` contract: framework calls finalize at most once per message on the single-message path, possibly multiple times (bounded retry on transient failure) on the batch path; adapters must make finalize idempotent or phase-tracked.
  Rationale: The current Haddock says both "exactly once" and "adapter enforces idempotency," which contradict each other; the batch retry loop already depends on the idempotent reading, so the contract is codified in that direction rather than adding a once-only latch to the framework, which would break batch retry.
  Date: 2026-07-02

- Decision: Kafka concurrency safety is achieved in this initiative by enforcing and documenting Serial-only operation, not by building a gap-tracking commit layer.
  Rationale: librdkafka commits the last stored offset per partition with no gap awareness, so any out-of-order store can commit past unprocessed messages. A lowest-contiguous-offset tracker (the Broadway-Kafka approach) is the correct long-term fix but is new machinery with its own failure modes; enforcing Serial closes the data-loss hole now. Gap tracking is recorded as excluded future work.
  Date: 2026-07-02

- Decision: PGMQ prefetch is removed from the public configuration (or gated behind an explicitly experimental flag) rather than fixed in this initiative.
  Rationale: The deadlock lies in the interaction of streamly's `parBuffered` channel with effectful's unlifting; the project's own example disables prefetch with a deadlock warning while the README recommends it. Removing the footgun is immediate; a real fix requires upstream investigation out of scope here. EP-27 records the reproduction steps for future work.
  Date: 2026-07-02

- Decision: `PartitionedInOrder` + concurrent modes is first rejected by `validatePolicy`, then (second milestone, optional) implemented via partition-keyed dispatch reusing the batch path's keyed-scheduler machinery.
  Rationale: The rejection is a one-line change that immediately stops the silent ordering-guarantee violation; the keyed dispatch is real machinery that deserves its own milestone with property tests. Shipping the rejection first means correctness does not wait on the feature.
  Date: 2026-07-02

- Decision: EP-24 completed the partition-keyed dispatch path rather than keeping the validation rejection permanent.
  Rationale: The existing EP-23 keyed batch scheduler was already bounded and structured enough to extract into a generic scheduler. Property tests now demonstrate same-partition FIFO finalization, exactly-once finalization, global concurrency bounds, and cross-partition parallelism.
  Date: 2026-07-02

- Decision: All core plans ship in a single shibuya-core 0.8.0.0 release owned by EP-25; EP-22/EP-23 write changelog entries without bumping the version, EP-24 opens the unreleased 0.8.0.0 changelog heading, and no intermediate core release is published mid-initiative.
  Rationale: EP-24 (validation rejection) and EP-25 (API cleanup) are both PVP-major; publishing them separately would burn two major versions within one remediation initiative and force adapter repos through two migration cycles. The adapters pin a git/local core during the initiative and migrate once.
  Date: 2026-07-02

- Decision: All child plans live in this repository's `docs/plans/`, including those directing work in the adapter repositories.
  Rationale: Follows the existing precedent of plans 13–15 (adapter upgrades for the Envelope headers field), keeping one registry and one place to track the initiative.
  Date: 2026-07-02


## Outcomes & Retrospective

(To be filled during and after implementation.)

Revision note, 2026-07-02: EP-28 was marked In Progress and the master Surprises & Discoveries section was updated with the Kafka adapter's `shibuya-core` 0.8 migration and validation-environment findings from M1.
