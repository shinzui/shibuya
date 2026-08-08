---
title: "Partition-keyed in-order processing"
type: Capability
description: "Process and acknowledge messages sharing a partition key in arrival order while distinct partitions run concurrently up to a configured bound."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-5
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.8.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Policy
  - Shibuya.Internal.Runner.KeyedScheduler
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/Runner/PartitionOrderingSpec.hs
    proves: Same-key messages are processed and acknowledged in arrival order while distinct keys run concurrently.
  - kind: module
    resource: shibuya-core/src/Shibuya/Internal/Runner/KeyedScheduler.hs
    proves: The per-key dispatch that enforces the guarantee.
---

# Partition-keyed in-order processing

**Builds on:** [CAP-4 — ordering and concurrency policies](ordering-and-concurrency-policies.md).

Kafka-style ordering: messages carrying the same `Envelope.partition` key are processed *and
acknowledged* in arrival order, distinct partition keys run concurrently up to the configured
bound, and messages with no partition key are unconstrained.

This is what lets a consumer keep per-entity ordering — all events for one account, one order,
one aggregate — without giving up throughput across entities, which is the usual cost of
`StrictInOrder` + `Serial`.

## Why this is its own capability

It is recorded separately from [CAP-4](ordering-and-concurrency-policies.md) rather than
widening that capability's `since`. `PartitionedInOrder` existed as an ordering policy earlier,
but enforcement for single-message processors combined with `Ahead` or `Async` arrived in
0.8.0.0. Folding it into CAP-4 would mean either claiming this behavior back to 0.1.0.0 or
silently moving CAP-4's `since` forward — both misinform a consumer pinning an older version.

## Limits

- Acknowledgement order is preserved per key, which means a slow message blocks its own
  partition. A hot key is a throughput ceiling.
- Not available on batching processors: a batch is scheduled by `BatchKey`, not by
  `Envelope.partition`, and the combination is rejected at configuration time.
- Messages with no partition key are unconstrained — they are not implicitly assigned a shared
  partition.
