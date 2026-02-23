# AckHalt Implementation Plan

## Overview

`AckHalt` is a decision that handlers can return to signal that processing should stop. Currently, it's defined and recorded in metrics but doesn't actually stop processing.

## Current Behavior

### Processor.hs (lines 63-66)
```haskell
-- TODO: Handle AckHalt by propagating up
case decision of
  AckHalt _ -> pure () -- For now, just continue. Runner should handle halt.
  _ -> pure ()
```

### Supervised.hs (lines 280-308)
```haskell
case result of
  -- ...
  Right (AckHalt reason) -> updateHalted metricsVar reason
  -- ...

updateHalted :: (IOE :> es) => TVar ProcessorMetrics -> HaltReason -> Eff es ()
updateHalted metricsVar reason = do
  now <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    m & #state .~ Failed (haltReasonText reason) now
```

**Problem:** After `updateHalted`, the loop in `processUntilDrained` continues calling `processMessageFromInbox`, processing more messages.

---

## Design Decision: How to Signal Halt

### Option A: Exception-based (Recommended)

Throw a custom exception that propagates up to the supervisor.

**Pros:**
- Fits NQE supervision model naturally
- Immediate termination, no extra checks in loop
- Supervisor can decide restart policy
- Clean stack unwinding

**Cons:**
- Exceptions for control flow (though this is idiomatic in Haskell for cancellation)

### Option B: Return-based

Change processor loop to return `Either HaltReason ()`.

**Pros:**
- Explicit in types
- No exception machinery

**Cons:**
- Requires changing all intermediate functions to propagate Either
- More intrusive changes

### Option C: TVar-based

Use a `TVar Bool` to signal halt condition.

**Pros:**
- Non-local signaling without exceptions

**Cons:**
- Requires checking TVar after every message
- Less immediate (message in progress completes first regardless)
- More state to manage

**Recommendation:** Option A (Exception-based) - aligns with how NQE handles child termination and keeps the loop code simple.

---

## Critical: Multi-Processor Ramifications

### The `link` Problem

Currently, `Supervised.hs:125-126` links each child to its parent:

```haskell
-- Link so exceptions propagate to the parent
unsafeEff_ $ UIO.link supervisedChild
```

This means **any exception from a child propagates to the calling thread**. With the current architecture:

```
runApp
  └── spawnProcessors (linked thread)
        ├── Processor A (linked)
        ├── Processor B (linked)
        └── Processor C (linked)
```

**If Processor A throws `ProcessorHalt`:**
1. Exception propagates via `link` to `spawnProcessors` thread
2. `runApp` fails with that exception
3. **All processors effectively die** (master and coordination lost)

The NQE supervisor's strategy (`OneForOne`, `OneForAll`) is **irrelevant** because `link` short-circuits it.

### Why `link` Was Added

The `link` ensures the parent is notified immediately when a child fails. Without it:
- Child failures are silent until explicitly waited on
- Resources may leak if failures go unnoticed

### Design Options for Halt Isolation

#### Option H1: Catch `ProcessorHalt` Before Propagation (Recommended)

Wrap the processor in a handler that catches `ProcessorHalt` and converts it to a normal exit:

```haskell
-- In runIngesterAndProcessor or runSupervised
runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
  `catch` \(ProcessorHalt reason) -> do
    -- Halt is intentional, not a failure
    -- Update metrics to Halted state (already done before throw)
    -- Exit gracefully without propagating
    pure ()
```

**Behavior:**
- `ProcessorHalt` stops only that processor
- Other processors continue unaffected
- Supervisor sees normal exit, no restart triggered
- `link` still catches unexpected exceptions

**Pros:**
- Only the halted processor stops
- Clean separation: halt ≠ failure
- Other processors unaffected

**Cons:**
- `ProcessorHalt` not visible to parent (must check metrics)

#### Option H2: Remove `link` Entirely

```haskell
-- Remove this line from runSupervised:
-- unsafeEff_ $ UIO.link supervisedChild
```

**Behavior:**
- Child exceptions don't propagate to parent automatically
- Supervisor handles child exits per strategy
- Must explicitly `wait` on children to see failures

**Pros:**
- Full supervisor control
- Isolated failures by default

**Cons:**
- Silent failures if not monitoring
- May need manual health checks

#### Option H3: Halt Stops All Processors (Current Behavior with Exception)

Keep `link`, let `ProcessorHalt` propagate.

**Behavior:**
- Any halt brings down everything
- "Fail fast" philosophy

**Pros:**
- Explicit: halt = system-wide stop
- Simple mental model

**Cons:**
- Can't have independent processor lifecycles
- `HaltOrderedStream` for one queue kills unrelated queues

### Recommendation: Option H1

**Catch `ProcessorHalt` and convert to graceful exit.** Rationale:

1. **Use case clarity**: `HaltOrderedStream` is for "this queue hit a processing boundary" - it shouldn't affect the orders queue when the events queue hits a halt.

2. **Failure vs Intentional Stop**: A halt is the handler saying "I'm done" - it's not a failure. It shouldn't trigger failure propagation.

3. **Observability**: Metrics already show the halted state. Parent can poll or use callbacks.

4. **`link` still useful**: Unexpected exceptions (bugs, resource failures) still propagate immediately.

### Implementation for Option H1

**File:** `shibuya-core/src/Shibuya/Runner/Supervised.hs`

```haskell
import Shibuya.Runner.Halt (ProcessorHalt (..))

runSupervised master inboxSize procId adapter handler = do
  -- ... existing setup ...

  supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    addChild master.state.supervisor $
      runInIO $
        -- Catch ProcessorHalt so it doesn't propagate via link
        (runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
          `catch` handleHalt)
          `finally` unregisterProcessor master procId

  -- Link still catches unexpected exceptions
  unsafeEff_ $ UIO.link supervisedChild
  -- ...

  where
    -- ProcessorHalt is intentional, convert to normal exit
    handleHalt :: ProcessorHalt -> Eff es ()
    handleHalt (ProcessorHalt _reason) = pure ()
    -- Metrics already updated before throw, just exit cleanly
```

### Behavior Matrix

| Scenario | Option H1 (Recommended) | Option H2 (No link) | Option H3 (Propagate) |
|----------|------------------------|---------------------|----------------------|
| Processor A halts | A stops, B/C continue | A stops, B/C continue | All crash |
| Processor A throws unexpected error | All crash (via link) | B/C continue | All crash |
| Processor A stream exhausts | A completes, B/C continue | A completes, B/C continue | A completes, B/C continue |
| Parent checks status | Via metrics | Via metrics + wait | N/A (crashed) |

### User-Facing Semantics (to Document)

With Option H1 implemented:

> **Halt Isolation**: When a handler returns `AckHalt`, only that processor stops. Other processors continue running independently. To stop all processors, use `stopApp` or have each handler implement coordinated shutdown logic.
>
> **Failure Propagation**: Unexpected exceptions (bugs, resource errors) still propagate to the parent, failing the entire application. This ensures failures are noticed immediately.

---

## Implementation Steps

### Step 1: Define ProcessorHalt Exception

Create the exception type in a shared location.

**File:** `shibuya-core/src/Shibuya/Runner/Halt.hs` (new file)

```haskell
-- | Halt exception for processor termination.
-- Thrown when a handler returns AckHalt to stop processing.
module Shibuya.Runner.Halt
  ( ProcessorHalt (..),
  )
where

import Control.Exception (Exception)
import Shibuya.Core.Ack (HaltReason)
import Shibuya.Prelude

-- | Exception thrown when processing should halt.
-- The supervisor catches this to handle graceful shutdown.
data ProcessorHalt = ProcessorHalt
  { reason :: !HaltReason
  }
  deriving stock (Show, Generic)

instance Exception ProcessorHalt
```

### Step 2: Export from Shibuya.Runner Module

**File:** `shibuya-core/src/Shibuya/Runner.hs`

Add to exports:
```haskell
-- * Halt Exception
ProcessorHalt (..),
```

### Step 3: Update Supervised.hs to Throw and Catch Halt

**File:** `shibuya-core/src/Shibuya/Runner/Supervised.hs`

Add imports:
```haskell
import Shibuya.Runner.Halt (ProcessorHalt (..))
import UnliftIO (throwIO, catch)
```

#### 3a. Throw ProcessorHalt in processMessageFromInbox

Modify `processMessageFromInbox` to throw after updating metrics:

```haskell
-- Current (around line 280-291):
case result of
  Right AckOk -> updateSuccess metricsVar
  Right (AckRetry _) -> updateSuccess metricsVar
  Right (AckDeadLetter _) -> updateFailed metricsVar
  Right (AckHalt reason) -> updateHalted metricsVar reason
  Left errMsg -> do
    -- ... error handling

-- New:
case result of
  Right AckOk -> updateSuccess metricsVar
  Right (AckRetry _) -> updateSuccess metricsVar
  Right (AckDeadLetter _) -> updateFailed metricsVar
  Right (AckHalt reason) -> do
    updateHalted metricsVar reason
    liftIO $ throwIO $ ProcessorHalt reason  -- Stops the processing loop
  Left errMsg -> do
    -- ... error handling (unchanged)
```

#### 3b. Catch ProcessorHalt in runSupervised (Halt Isolation)

Wrap the processor so `ProcessorHalt` doesn't propagate via `link`:

```haskell
-- Current runSupervised (around line 119-123):
supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
  addChild master.state.supervisor $
    runInIO $
      runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
        `finally` unregisterProcessor master procId

-- New:
supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
  addChild master.state.supervisor $
    runInIO $
      -- Catch ProcessorHalt to prevent propagation via link
      -- (Halt is intentional, not a failure - other processors should continue)
      (runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
        `catch` \(ProcessorHalt _) -> pure ())  -- Convert halt to graceful exit
        `finally` unregisterProcessor master procId
```

**Why this matters:**
- Without the catch, `link` propagates `ProcessorHalt` to the parent
- This would crash all processors when one halts
- The catch ensures halt stops only the halting processor
- Unexpected exceptions still propagate (bugs, resource failures)

### Step 4: Add Halted State to ProcessorState (Optional Enhancement)

**File:** `shibuya-core/src/Shibuya/Runner/Metrics.hs`

This is optional but provides better observability:

```haskell
-- Current:
data ProcessorState
  = Idle
  | Processing !Int !UTCTime
  | Failed !Text !UTCTime
  | Stopped
  deriving stock (Eq, Show, Generic)

-- Enhanced (optional):
data ProcessorState
  = Idle
  | Processing !Int !UTCTime
  | Failed !Text !UTCTime
  | Halted !HaltReason !UTCTime  -- NEW: explicit halt state
  | Stopped
  deriving stock (Eq, Show, Generic)
```

If adding `Halted` state, update `updateHalted` in Supervised.hs:

```haskell
updateHalted :: (IOE :> es) => TVar ProcessorMetrics -> HaltReason -> Eff es ()
updateHalted metricsVar reason = do
  now <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    m & #state .~ Halted reason now  -- Use Halted instead of Failed
```

**Note:** Adding `Halted` is a breaking change for pattern matches on `ProcessorState`. Consider this carefully.

### Step 5: Update Processor.hs (Cleanup Only)

The `Processor.hs` module's `processOne` function has a TODO comment that becomes obsolete:

**File:** `shibuya-core/src/Shibuya/Runner/Processor.hs`

```haskell
-- Remove or update the TODO comment:
processOne handler inbox = do
  ingested <- receive inbox
  decision <- handler ingested
  ingested.ack.finalize decision
  -- AckHalt is handled by the runner (Supervised.hs throws ProcessorHalt)
```

The `Processor` module doesn't need to throw because it's a low-level building block. The `Supervised` runner handles halt semantics.

### Step 6: Handle Exception in runSupervised Context

The exception will propagate up through the supervised child. NQE's supervisor will see the child terminate with `ProcessorHalt`.

**Behavior:**
- Child terminates with `ProcessorHalt` exception
- Supervisor's default behavior: log and potentially restart based on strategy
- Metrics show `Halted` (or `Failed`) state

If you want to distinguish halt from failure for supervisor restart policy, you may need to catch `ProcessorHalt` at the `runIngesterAndProcessor` level and set a specific exit status.

---

## Testing Plan

### Test 1: AckHalt Stops Processing

```haskell
test "AckHalt stops processing" $ do
  messagesProcessed <- newIORef (0 :: Int)

  let handler ingested = do
        count <- readIORef messagesProcessed
        modifyIORef' messagesProcessed (+ 1)
        if count >= 2
          then pure $ AckHalt (HaltFatal "stopping after 3")
          else pure AckOk

  -- Create adapter with 10 messages
  adapter <- testAdapterN 10

  -- Run processor (should stop after 3 messages)
  result <- try $ runWithMetrics 10 (ProcessorId "test") adapter handler

  -- Verify
  case result of
    Left (ProcessorHalt _) -> do
      count <- readIORef messagesProcessed
      count `shouldBe` 3  -- Processed exactly 3 before halt
    Right _ ->
      fail "Expected ProcessorHalt exception"
```

### Test 2: Metrics Show Halted State

```haskell
test "AckHalt updates metrics correctly" $ do
  -- ... setup ...

  metrics <- getMetrics supervisedProcessor
  case metrics.state of
    Halted reason _ -> reason `shouldBe` HaltFatal "test halt"
    other -> fail $ "Expected Halted state, got: " ++ show other
```

### Test 3: Halt Isolation (Critical)

```haskell
test "AckHalt in one processor doesn't affect others" $ do
  master <- startMaster OneForOne

  -- Processor A: halts after 2 messages
  let handlerA ingested = do
        count <- readIORef countA
        modifyIORef' countA (+ 1)
        if count >= 1
          then pure $ AckHalt (HaltFatal "A stopping")
          else pure AckOk

  -- Processor B: processes all messages normally
  let handlerB _ = do
        modifyIORef' countB (+ 1)
        pure AckOk

  adapterA <- testAdapterN 10
  adapterB <- testAdapterN 10

  countA <- newIORef (0 :: Int)
  countB <- newIORef (0 :: Int)

  spA <- runSupervised master 10 (ProcessorId "A") adapterA handlerA
  spB <- runSupervised master 10 (ProcessorId "B") adapterB handlerB

  -- Wait for both to complete (A halts, B finishes all)
  threadDelay 1000000  -- Give time to process

  -- Verify A stopped early
  aCount <- readIORef countA
  aCount `shouldBe` 2  -- Processed 2, then halted

  -- Verify B continued unaffected
  bCount <- readIORef countB
  bCount `shouldBe` 10  -- Processed all 10

  -- Verify metrics
  metricsA <- getMetrics spA
  metricsA.state `shouldSatisfy` isHalted

  metricsB <- getMetrics spB
  metricsB.stats.processed `shouldBe` 10
```

### Test 4: Unexpected Exceptions Still Propagate

```haskell
test "Unexpected exceptions propagate via link" $ do
  master <- startMaster OneForOne

  let handler _ = error "Unexpected bug!"

  adapter <- testAdapterN 5

  sp <- runSupervised master 10 (ProcessorId "test") adapter handler

  -- This should propagate and fail
  result <- try $ waitForChild sp.child

  case result of
    Left (e :: SomeException) ->
      displayException e `shouldContain` "Unexpected bug!"
    Right () ->
      fail "Expected exception to propagate"
```

---

## Files Changed Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `Shibuya/Runner/Halt.hs` | New | ProcessorHalt exception type |
| `Shibuya/Runner/Supervised.hs` | Modify | Throw ProcessorHalt on AckHalt; catch for halt isolation |
| `Shibuya/Runner/Metrics.hs` | Optional | Add Halted constructor to ProcessorState |
| `Shibuya/Runner/Processor.hs` | Cleanup | Remove/update TODO comment |
| `Shibuya/Runner.hs` | Export | Export ProcessorHalt |
| Tests | New | 4 new tests (stop, metrics, isolation, propagation) |

---

## Breaking Changes

### If Adding Halted State (Optional)
- `ProcessorState` gains new constructor
- Pattern matches on `ProcessorState` need updating
- Downstream code checking for `Failed` to detect halts needs updating

### Exception Semantics
- Previously: AckHalt was silently ignored, processing continued
- Now: AckHalt throws `ProcessorHalt`, terminating the processor

This is the documented/expected behavior, so it's a bug fix, not a breaking change in intent.

---

## Migration Guide

### For Users Checking ProcessorState

If you're pattern matching on `ProcessorState` and we add `Halted`:

```haskell
-- Before:
case state of
  Idle -> ...
  Processing n t -> ...
  Failed msg t -> ...
  Stopped -> ...

-- After:
case state of
  Idle -> ...
  Processing n t -> ...
  Failed msg t -> ...
  Halted reason t -> ...  -- NEW: handle halted processors
  Stopped -> ...
```

### For Users Catching Processor Exceptions

```haskell
-- To detect halt vs failure:
result <- try $ runSupervised ...
case result of
  Left (fromException -> Just (ProcessorHalt reason)) ->
    -- Graceful halt, handler requested stop
    logInfo $ "Processor halted: " <> show reason
  Left err ->
    -- Unexpected error
    logError $ "Processor failed: " <> show err
  Right () ->
    -- Stream exhausted normally
    logInfo "Processor completed"
```

---

## Implementation Checklist

- [ ] Create `Shibuya/Runner/Halt.hs` with `ProcessorHalt` exception
- [ ] Update `Shibuya/Runner/Supervised.hs`:
  - [ ] Throw `ProcessorHalt` in `processMessageFromInbox` on `AckHalt`
  - [ ] Catch `ProcessorHalt` in `runSupervised` for halt isolation
- [ ] (Optional) Add `Halted` constructor to `ProcessorState`
- [ ] Update `Shibuya/Runner/Processor.hs` TODO comment
- [ ] Export `ProcessorHalt` from `Shibuya/Runner.hs`
- [ ] Add tests:
  - [ ] AckHalt stops processing
  - [ ] Metrics show halted state
  - [ ] Halt isolation (one processor halting doesn't affect others)
  - [ ] Unexpected exceptions still propagate
- [ ] Update documentation to describe halt semantics and isolation behavior
