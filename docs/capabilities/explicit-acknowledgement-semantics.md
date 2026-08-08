---
title: "Explicit acknowledgement semantics"
type: Capability
description: "Handlers return an intent — ack, retry, dead-letter, or halt — and the framework performs the corresponding queue operation and owns finalization."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Core.Ack
  - Shibuya.Core.AckHandle
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/Core/AckSpec.hs
    proves: Each ack decision maps to the expected queue operation.
  - kind: module
    resource: shibuya-core/src/Shibuya/Core/Ack.hs
    proves: The closed set of decisions a handler can return.
  - kind: module
    resource: shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs
    proves: Finalization is performed by the framework, not by handler code.
---

# Explicit acknowledgement semantics

**Builds on:** [CAP-1 — backend-agnostic queue processing](backend-agnostic-queue-processing.md).

A handler never calls `ack`, `nack`, or `delete` itself. It returns a value describing what
*should* happen, and the framework performs it:

```haskell
AckOk                              -- processed successfully
AckRetry (RetryDelay 30)           -- make visible again in 30 seconds
AckDeadLetter (InvalidPayload msg) -- route to the dead-letter queue
AckHalt (HaltFatal reason)         -- stop processing entirely
```

Separating intent from mechanics is what makes a handler testable without a broker and portable
across backends whose acknowledgement primitives differ.

## Why it matters in practice

The framework owning finalization is what lets it guarantee that every message is finalized
exactly once per delivery even when a handler throws, when a batch partially fails, or when the
application is shutting down. A handler that performed its own acknowledgement would have to
re-derive that behavior, correctly, at every call site.

## Limits

- Adapters must make finalize **idempotent**. A keyed batch may be retried on the batch path, so
  the same finalization can be attempted more than once (see the 0.8.0.0 batch-path hardening
  notes in [`../../CHANGELOG.md`](../../CHANGELOG.md)).
- `AckRetry (RetryDelay 0)` is an explicit immediate retry, not a dropped acknowledgement.
- Dead-letter routing is performed by the adapter; a backend with no dead-letter concept cannot
  honor `AckDeadLetter`.
