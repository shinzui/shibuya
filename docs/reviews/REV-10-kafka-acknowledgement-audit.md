---
type: Review
title: "Kafka retry barriers can move past an unresolved earlier offset"
description: "Kafka retry barriers can move past an unresolved earlier offset; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-10
subject: mori://shinzui/shibuya-kafka-adapter/packages/shibuya-kafka-adapter
subjectKind: component
component: shibuya-kafka-adapter
reviewedSha: 6c0cd3fc840c9f5ba48558ca94c7d826a3da6c9f
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

# Kafka retry barriers can move past an unresolved earlier offset

Examined all four adapter source modules (Kafka, Internal, Config, Convert), with AckHandleTest and relevant shutdown tests. References below are relative to `mori://shinzui/shibuya-kafka-adapter`; file-level artifact URIs are pending. No repository files were modified.

## P1 — a second buffered retry overwrites the earliest barrier

Internal.mkAckHandle uses Map.insert for every AckRetry. Source filtering only checks records before yielding them; records already in Shibuya's inbox are outside that filter. Even with the documented Serial policy, this trace is reachable:

1. Offsets 42 and 43 enter the framework inbox before either is handled.
2. Offset 42 retries: barrier becomes 42 and seek goes to 42.
3. Already-buffered 43 retries: barrier becomes 43 and seek goes to 43.
4. A redelivered 43 succeeds: storeGuarded clears the barrier and stores its offset; a later commit can pass 42 although 42 never succeeded.

The ingester may remain blocked behind buffered work during the two seeks; serial handlers do not imply zero read-ahead. Preserve the earliest unresolved offset and invalidate or gate stale deliveries at the finalization boundary. Add a mocked two-retry trace and broker replay test. Existing barrier test covers retry 42, success 43, success 42, not this sequence.

## P1 — acknowledgement failure can disappear after source termination

ackAttempt records exhausted/fatal errors in fatalError and returns success. Only the next kafkaSource step throws the slot. If shutdown has already ended the source, finalization during draining can fail without any future reader observing it; core metrics can report success and waitApp can complete. Throw/return finalization failure directly or provide a failure channel monitored through drain completion. Existing mock tests explicitly expect no throw, but do not establish end-of-source safety.

## Documented limitations, not newly discovered regressions

Serial-only processing, no actual DLQ producer, and absence of cooperative rebalance fencing are explicit contracts. The consumer mutex has bracketed release and blocking poll/seek operations are capped. Shutdown commits before core draining; final stored offsets rely on later auto-commit/consumer closure, as documented.

Findings above are source-confirmed interleavings, not broker reproductions. The local package set was inspected, but adapter/broker integration was not rerun. This is not Kafka release approval. Remediation belongs to this adapter project; the core master-loop patch does not fix either issue.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
