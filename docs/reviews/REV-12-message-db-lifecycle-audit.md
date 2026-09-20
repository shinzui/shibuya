---
type: Review
title: "MessageDB checkpoint and shutdown protocols have multiple lifecycle defects"
description: "MessageDB checkpoint and shutdown protocols have multiple lifecycle defects; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-12
subject: mori://shinzui/shibuya-message-db-adapter/packages/shibuya-message-db-adapter
subjectKind: component
component: shibuya-message-db-adapter
reviewedSha: fa7b958462a34b9ac12cf26995f93625d4fcd2ef
coverage: full
reviewedAt: "2026-09-20T03:42:33Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: changes-requested
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Lifecycle and concurrency examination of the named component. Full refers to
  source coverage at this commit, not exhaustive testing or security certification.
  Executed probes and source-only findings are explicitly distinguished below.
---

# MessageDB checkpoint and shutdown protocols have multiple lifecycle defects

Examined all six source modules: MessageDb, Config, Convert, Internal, Internal.InflightState and Internal.Dlq, with ledger/retry tests. References are project-relative to `mori://shinzui/shibuya-message-db-adapter`; file artifact URIs are pending. The adapter targets an older core; EP-36 already tracks 0.9 API compatibility. Do not interpret these findings as proof of a successfully built 0.9 adapter.

## P1 — category gaps permanently pin checkpoints

InflightState.advanceCheckpointTo looks up exactly lastSaved+1, incrementing arithmetically. Category streams contain store-wide global positions with gaps for other categories. Seed 0 and a fully acknowledged first category message at position 2 never advances. Later completed entries accumulate and restart replays from the stale checkpoint.

The independent MessageDbLedgerProbe compiles the actual InflightState source and exercises this case. Supporting database source is `mori://message-db/message-db`, project-relative `message-db/database/functions/get-category-messages.sql`: it filters category while returning global_position, ordered but not renumbered. Track the ordered sequence of delivered positions and unresolved gaps in that sequence, not every integer in the database.

## P1 — retry shutdown can spin forever

awaitRetryHeadOrShutdown gives the nonempty retry queue left priority over the shutdown branch. retryFiber sees the head, skips popping it when stopped, then loops. Once its delay has elapsed, the same retained head is returned immediately forever. This is source-confirmed; a full retry-fiber runtime probe was not run. Prefer shutdown before reading work and break the loop when stopped. Keep explicit ownership/join/cancel for both background fibers.

## P2 — idle source ignores shutdown until a message is produced

messageDbSource applies takeUntilShutdown after empty-batch filtering and flattening. Empty polls never reach its predicate, so an idle source continues polling after shutdown. Core's drain then requires timeout/force-stop. Check shutdown before polling and make waits wakeable; test an empty category with no later writes.

## P2 — checkpoint state advances before persistence succeeds

advanceCheckpointTo removes entries and updates lastSaved before storeCheckpoint is called. The background persister is forked without a monitored result. If persistence fails and no newer event arrives, shutdown's advanceCheckpointTo returns Nothing and never retries the lost checkpoint claim. The ledger probe also demonstrates this destructive claim behavior; no database outage was injected. Track pending versus durable checkpoint state and observe/retry persister failure.

## Other boundaries

DLQ write errors are deliberately logged then marked complete, so the configured write-to-stream strategy is best-effort under failure, not guaranteed durable DLQ. Retry-channel capacity excludes entries already moved from the bounded queue to the unbounded TChan. Grouping hashes the category of messages while polling one category, so a normal single-category subscription does not spread its entity streams across members. These are contract/resource concerns to resolve alongside the lifecycle fixes, not newly reproduced broker losses.

No external files were changed, no live database was used, and no adapter release approval is given. The core GC fix does not correct these owning-adapter problems.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
