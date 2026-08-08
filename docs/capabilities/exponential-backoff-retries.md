---
title: "Exponential backoff retries with jitter"
type: Capability
description: "Compute exponentially growing, jittered retry delays from the adapter's redelivery count with a single call, following AWS's full-jitter recommendation."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-7
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shibuya-core
interface:
  - Shibuya.Core.Retry
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shibuya-core/test/Shibuya/Core/RetrySpec.hs
    proves: Delay growth, jitter strategies, cap behavior, and the fallback when no attempt count is available.
  - kind: module
    resource: shibuya-core/src/Shibuya/Core/Retry.hs
    proves: A pure evaluator (exponentialBackoffPure) alongside the effectful helper, so backoff is testable without IO.
  - kind: guide
    resource: README.md
    proves: The documented default policy and handler integration.
---

# Exponential backoff retries with jitter

**Builds on:** [CAP-2 — explicit acknowledgement semantics](explicit-acknowledgement-semantics.md).

A handler that retries on a transient failure needs a delay that grows and that does not
synchronize every failing consumer into the same retry instant. Both are one call:

```haskell
import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)

myHandler msg = do
  result <- tryProcess msg.envelope.payload
  case result of
    Right ()  -> pure AckOk
    Left _err -> retryWithBackoff defaultBackoffPolicy msg.envelope
```

`defaultBackoffPolicy` follows AWS's *exponential backoff with full jitter* recommendation:
1 second base, factor 2, capped at 5 minutes. The available `Jitter` strategies are `NoJitter`,
`FullJitter` (the default), and `EqualJitter`.

## Where the attempt count comes from

The delay grows using `msg.envelope.attempt` — the *adapter's* redelivery counter, such as
pgmq's `read_count`, rather than state the framework keeps. That makes backoff correct across
restarts and across competing consumers, because the count lives with the message.

## Limits

- Backends that do not surface a redelivery count leave `attempt` as `Nothing`, and the helper
  falls back to the base delay. On such a backend the delay does not grow.
- `exponentialBackoffPure` is available for tests and for callers that need the delay without
  performing an effect.
- This computes a delay; honoring it is the backend's visibility-timeout or delay mechanism.
