# Exponential Backoff for Retries — Design Findings

Status: design notes, not yet scheduled.
Scope: spans `shibuya-core` and `shibuya-pgmq-adapter`.

## Current state

`Shibuya.Core.Ack` (`shibuya-core/src/Shibuya/Core/Ack.hs`) defines:

```haskell
newtype RetryDelay = RetryDelay { unRetryDelay :: NominalDiffTime }

data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
```

The handler returns an absolute `RetryDelay` for each retry. The PGMQ adapter
(`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:174`) honors it by
calling pgmq's `changeVisibilityTimeout` so the message reappears after that
delay. A `maxRetries` ceiling is enforced by the adapter against pgmq's
`readCount` (`Internal.hs:260`); messages exceeding it are auto-dead-lettered
before ever reaching the handler.

There is no built-in backoff policy in either core or adapter — the handler
must compute the delay itself, but it has no input to compute one from.

## The gap

`Envelope` (`shibuya-core/src/Shibuya/Core/Types.hs:45`) carries no attempt /
delivery count:

```haskell
data Envelope msg = Envelope
  { messageId    :: !MessageId
  , cursor       :: !(Maybe Cursor)
  , partition    :: !(Maybe Text)
  , enqueuedAt   :: !(Maybe UTCTime)
  , traceContext :: !(Maybe TraceHeaders)
  , payload      :: !msg
  }
```

A handler therefore cannot compute `base * factor^attempt` because it does not
know `attempt`. Exponential backoff is impossible to express in the current
shape of the API, even though the underlying mechanism (variable
`RetryDelay`) already supports it.

## Recommended approach

Keep `Ack.hs` mechanism-free (per its own docstring: *"Handlers decide
meaning, not mechanics"*) and expose enough envelope information for the
handler to compute backoff. Provide a small helper module so every handler
doesn't reinvent it.

### shibuya-core changes

1. **Surface the attempt count on `Envelope`.**

   ```haskell
   data Envelope msg = Envelope
     { ...
     , attempt :: !(Maybe Int)   -- 0 on first delivery; Nothing if adapter cannot track
     , ...
     }
   ```

   `Maybe` because not every adapter has a delivery counter (Kafka, for
   example, has none natively).

2. **Add `Shibuya.Core.Retry`** with a pure policy and evaluator:

   ```haskell
   data Jitter = NoJitter | FullJitter | EqualJitter | DecorrelatedJitter

   data BackoffPolicy = BackoffPolicy
     { base     :: !NominalDiffTime
     , factor   :: !Double
     , maxDelay :: !NominalDiffTime
     , jitter   :: !Jitter
     }

   exponentialBackoff :: BackoffPolicy -> Int -> IO RetryDelay
   ```

   Jitter is non-optional in practice — exponential backoff without it
   produces thundering herds when many messages fail simultaneously. Offering
   `FullJitter` as the default matches AWS's published recommendation.

   The `IO` is only because jitter samples randomness; the alternative is to
   thread a `StdGen` through, which is awkward for handler authors. A pure
   variant `exponentialBackoffPure :: BackoffPolicy -> Int -> Double ->
   RetryDelay` taking a `[0,1)` jitter sample is easy to add for tests.

### shibuya-pgmq-adapter changes

3. **Populate `attempt` from `readCount`.** In
   `pgmqMessageToEnvelope` (`Convert.hs:83`):

   ```haskell
   attempt = Just (fromIntegral msg.readCount - 1)
   ```

   pgmq increments `readCount` *on read*, so on first delivery it is `1`;
   subtract one so the handler sees the conventional "this is retry #N"
   semantic where the first try is `0`.

4. **Clamp the visibility-timeout extension.** `changeVisibilityTimeout`
   takes `Int32` seconds (`Internal.hs:182`). A policy with a long `maxDelay`
   could overflow — the policy module should clamp to a safe ceiling, and the
   adapter should defensively cap on the way out as well. Worth a unit test.

5. **No change to `maxRetries`.** The auto-DLQ path at `Internal.hs:260`
   already terminates the chain before the handler sees a doomed message, so
   the backoff policy can be unbounded in attempts without risking infinite
   retry.

### Handler usage after the change

```haskell
handler env = do
  result <- tryProcess env.payload
  case result of
    Right () -> pure AckOk
    Left _  -> do
      delay <- exponentialBackoff myPolicy (fromMaybe 0 env.attempt)
      pure (AckRetry delay)
```

## Alternative considered: framework-evaluated policy

Push the policy into `RetryDelay` itself:

```haskell
data RetryDelay
  = FixedDelay !NominalDiffTime
  | ExponentialBackoff !BackoffPolicy
```

The framework (or each adapter) would then evaluate the policy using its own
attempt counter. This has nicer ergonomics for the handler — no need to read
`env.attempt` — and gives adapter-uniform backoff guarantees.

**Why not recommended:**

- Pushes mechanics into `Shibuya.Core.Ack`, contradicting its stated
  separation of concerns.
- Forces every adapter to either track an attempt count or fabricate one.
  pgmq has `readCount`, but other adapters (Kafka, in-memory test adapter)
  may not, and the failure mode of fabrication is silent backoff
  miscalculation.
- Makes `RetryDelay` no longer a value the handler fully owns — testing a
  handler that returns `ExponentialBackoff` requires running it through the
  framework to observe the resolved delay.

The handler-side approach (recommended) is strictly more flexible: a handler
that wants framework-uniform backoff can call the same `exponentialBackoff`
helper, while a handler that wants per-error-type policies (e.g. shorter
backoff for `429`, longer for `503`) can branch on the failure before calling
the helper. The framework-evaluated approach forecloses that.

## Open questions

- Should `attempt` be added to `Envelope` directly, or carried in a separate
  delivery-context record? Adding to `Envelope` is simpler but couples the
  type to a concept some adapters can't fill. Leaning toward `Maybe Int` on
  `Envelope` for ergonomics.
- Decorrelated jitter requires the *previous* delay as input, not just the
  attempt number. If we want it, the helper signature needs to change (or
  the handler tracks the previous delay itself). May be worth deferring.
- Does the in-memory test adapter (used in `shibuya-example`) need to
  simulate `readCount`? If it always returns `attempt = Just 0`, tests for
  exponential-backoff handlers will silently exercise only the first-attempt
  branch.

## Touched files (estimated)

- `shibuya-core/src/Shibuya/Core/Types.hs` — add `attempt` field
- `shibuya-core/src/Shibuya/Core/Retry.hs` — new module
- `shibuya-core/src/Shibuya/Core.hs` — re-export
- `shibuya-core/shibuya-core.cabal` — list new module
- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` — populate
  `attempt`
- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` — defensive
  clamp on VT extension
- Any in-tree mock/test adapters that build `Envelope` directly
