---
title: "Ordering and concurrency policies"
type: Capability
description: "Declare a processor's ordering guarantee and concurrency mode as data, with invalid combinations rejected before any message is consumed."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-4
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Policy
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/PolicySpec.hs
    proves: validatePolicy accepts legal ordering/concurrency pairs and rejects contradictory ones.
  - kind: module
    resource: shibuya-core/src/Shibuya/Policy.hs
    proves: OrderingPolicy and Concurrency are closed data types validated together.
  - kind: benchmark
    resource: shibuya-core-bench
    proves: Framework overhead is measured against a pure Streamly pipeline.
---

# Ordering and concurrency policies

**Builds on:** [CAP-1 — backend-agnostic queue processing](backend-agnostic-queue-processing.md).

Each processor declares two independent choices as data rather than as behavior scattered
through a handler:

```haskell
--   ordering    - Unordered | StrictInOrder | PartitionedInOrder
--   concurrency - Serial | Ahead Natural | Async Natural
```

`validatePolicy` rejects combinations that cannot be honored — `StrictInOrder` with anything
other than `Serial`, for instance — at configuration time, before a single message is consumed.
A guarantee you cannot satisfy is a startup error, not a production surprise.

## Choosing

- `Unordered` + `Async n` — the throughput default; up to `n` handlers run concurrently.
- `Unordered` + `Ahead n` — concurrent processing, results emitted in arrival order.
- `StrictInOrder` + `Serial` — event-sourced subscriptions, where a single out-of-order apply is
  a correctness bug.
- `PartitionedInOrder` — per-key ordering with cross-key concurrency; see
  [CAP-5](partition-keyed-in-order-processing.md).

`mkProcessor` builds the `Unordered` / `Serial` case for the common path.

## Limits

- Ordering is only as strong as the backend delivers. `StrictInOrder` preserves the order the
  adapter yields; it cannot repair a source that is already unordered.
- Batching processors reject `PartitionedInOrder` combined with `Ahead` or `Async`, because
  batches are scheduled by `BatchKey` rather than by `Envelope.partition`.
