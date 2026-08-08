---
title: "First-class batch processing"
type: Capability
description: "Accumulate messages by key into batches with size, timeout, and flush triggers, and acknowledge each message in a batch independently."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.8.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Batch
  - Shibuya.App
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/BatchSpec.hs
    proves: Batch keying, trigger evaluation, and configuration validation.
  - kind: test
    resource: shibuya-core/test/Shibuya/Batch/ReliabilitySpec.hs
    proves: Batches survive partial failure, consumer exceptions, and halt isolation without losing acknowledgements.
  - kind: test
    resource: shibuya-core/test/Shibuya/Runner/BatcherSpec.hs
    proves: Accumulation and trigger firing in the batcher stage.
  - kind: test
    resource: shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs
    proves: Per-message BatchAck decisions are applied to the right messages.
  - kind: test
    resource: shibuya-core/test/Shibuya/App/BatchSpec.hs
    proves: A pending partial batch is flushed and acknowledged on graceful shutdown.
  - kind: example
    resource: shibuya-example/app-batch/Main.hs
    proves: A runnable batching application.
---

# First-class batch processing

**Builds on:** [CAP-2 — explicit acknowledgement semantics](explicit-acknowledgement-semantics.md).

Handlers that are dramatically cheaper per message in bulk — a database `COPY`, a bulk index
write, a vendor API with a batch endpoint — get batching from the framework rather than
hand-rolling an accumulator with a timer.

```haskell
import Shibuya.Batch

processor = mkBatchProcessor myAdapter defaultBatchConfig handleBatch
```

Messages accumulate by `BatchKey` and a batch is emitted when a `BatchTrigger` fires: size
reached, timeout elapsed, or an explicit flush. `validateBatchConfig` rejects a configuration
that could never emit.

## Per-message acknowledgement

The part that is genuinely hard to hand-roll is partial failure. A batch handler returns a
`BatchAck` describing the outcome *per message*, not one verdict for the whole batch:

```haskell
ackAllOk                 -- every message succeeded
ackExcept failures       -- all succeeded except these
withFallback ...         -- a default decision for anything unclassified
failMessages ...         -- these specific messages failed
```

so a batch where three of five rows violated a constraint retries three messages and
acknowledges two, rather than replaying all five.

## Limits

- Batching cannot be combined with `PartitionedInOrder` + `Ahead`/`Async`: batches are
  scheduled by `BatchKey`, not by `Envelope.partition`.
- A keyed batch may be retried on the batch path, so **adapters must make finalize idempotent**.
- Batching trades latency for throughput. A timeout trigger is the floor on how long a message
  can sit unprocessed under low volume.
