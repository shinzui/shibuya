---
type: Review
title: "PGMQ lifecycle review retains an ambiguous-commit idempotency risk"
description: "PGMQ lifecycle review retains an ambiguous-commit idempotency risk; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-11
subject: mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter
subjectKind: component
component: shibuya-pgmq-adapter
reviewedSha: 392f7545af32ef893c24139fd194d16ec1172f75
coverage: full
reviewedAt: "2026-09-20T03:42:33Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: commented
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

# PGMQ lifecycle review retains an ambiguous-commit idempotency risk

Examined all adapter source modules (Pgmq, Internal, Config, Convert), and selected ChaosSpec assertions for finalization, shutdown and prefetch. Paths are relative to `mori://shinzui/shibuya-pgmq-adapter`; source-file artifact URIs are pending.

## Established behavior

Shutdown sets a TVar; the post-poll chunk gate releases a just-read chunk when it observes shutdown. Prefetched/unconsumed deliveries can remain invisible until their visibility timeout; this is documented delayed redelivery, not deletion or proven data loss. Core force-stop can interrupt polling. Lease extension clamps seconds to Int32 and maintains a monotonic local target for sequential calls. DLQ send and source deletion occur within one database transaction.

## P2 risk — ambiguous commit can duplicate a DLQ copy

Internal.mkAckHandle sets its in-memory finalized flag only after runDecision returns. deadLetterTransactionally sends the DLQ message before deleting the source and ignores the delete result. If PostgreSQL commits but the client receives a retryable connection error, a retry can send another DLQ copy even though the source was already deleted. The transaction prevents partial send/delete rollback errors; it does not itself deduplicate an ambiguous successful commit.

This is a source-level risk under an ambiguous-commit fault, not an injected database result or a claim that ordinary successful repeated finalize duplicates. Existing successful-finalize idempotence tests exercise the IORef guard after success, not lost commit confirmation. Require a durable idempotency key or source-existence/locking gate, and a commit-response-loss test before claiming retry-idempotent DLQ delivery.

Other boundaries: concurrent invocation of the same AckHandle is not serialized by readIORef/writeIORef; core normally finalizes a delivery sequentially, so no separate core-triggered race is claimed. Automatic dead-letter failure is reported through a callback, whose default is a no-op; the source message remains available for later redelivery.

No live PostgreSQL/PGMQ integration test was run in this audit. No additional deterministic adapter-specific loss/termination defect was established; the common core halt and finalizer findings still apply. This is a commented source review, not blanket adapter release approval.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
