# Priority 1: Critical Fixes (API/Behavior Mismatch)

These issues represent gaps between documented/expected behavior and actual implementation. Users relying on advertised features will experience unexpected behavior.

---

## 1.1 Implement Backpressure

### Problem
The `inboxSize` parameter in `runApp` and `runSupervised` is documented for backpressure but has no effect. The `Ingester.hs` module exists with bounded inbox logic but is never used.

**Current flow:**
```
Adapter.source → Stream.mapM processMessage → drain
```

**Expected flow:**
```
Adapter.source → Ingester (bounded inbox) → Processor → Handler
```

### Files to Modify
- `src/Shibuya/Runner/Supervised.hs` - Main changes
- `src/Shibuya/Runner/Ingester.hs` - May need adjustments
- `src/Shibuya/Runner/Processor.hs` - May need adjustments

### Implementation Plan

#### Step 1: Understand current Ingester/Processor design
Read and verify the existing `Ingester.hs` and `Processor.hs` implementations work correctly in isolation.

#### Step 2: Modify `runSupervised` to use bounded inbox
```haskell
-- Current (Supervised.hs:118-122)
supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
  addChild master.state.supervisor $
    runInIO $
      processStream metricsVar doneVar adapter handler
        `finally` unregisterProcessor master procId

-- New approach:
-- 1. Create bounded inbox using NQE
-- 2. Spawn ingester thread (adapter.source → inbox)
-- 3. Spawn processor thread (inbox → handler)
-- 4. Link both threads for supervision
```

#### Step 3: Update `processStream` or replace it
Either modify `processStream` to:
- Accept an inbox and use `Processor.runProcessor`, OR
- Split into two async operations (ingester + processor)

#### Step 4: Handle metrics in the new flow
Ensure `incReceived` is called by ingester, `incProcessed`/`incFailed` by processor.

#### Step 5: Add backpressure tests
- Test that fast producer blocks when inbox is full
- Test that slow consumer doesn't cause memory growth
- Test metrics are accurate under backpressure

### Breaking Changes
None expected - this implements documented behavior.

### Test Plan
1. Create adapter that produces messages faster than handler processes
2. Verify inbox size limits buffered messages
3. Verify `dropped` metric increments if using drop-on-full strategy (or blocking behavior)

---

## 1.2 Implement AckHalt

### Problem
`AckHalt` decision is defined but doesn't stop processing. Code has explicit TODO:

```haskell
-- Processor.hs:62-65
case decision of
  AckHalt _ -> pure () -- For now, just continue. Runner should handle halt.
  _ -> pure ()
```

### Files to Modify
- `src/Shibuya/Runner/Processor.hs` - Signal halt
- `src/Shibuya/Runner/Supervised.hs` - Handle halt signal
- `src/Shibuya/Runner/Metrics.hs` - Add `Halted` state (optional)

### Implementation Plan

#### Step 1: Define halt signaling mechanism
Options:
- **Option A:** Throw a custom `HaltException` that supervisor catches
- **Option B:** Return `Either HaltReason ()` from processor loop
- **Option C:** Use `MVar`/`TVar` to signal halt condition

Recommendation: **Option A** - fits NQE supervision model, allows supervisor to decide restart behavior.

#### Step 2: Create HaltException type
```haskell
-- New in Supervised.hs or a shared module
data ProcessorHalt = ProcessorHalt !HaltReason
  deriving (Show)

instance Exception ProcessorHalt
```

#### Step 3: Update Processor to throw on halt
```haskell
-- Processor.hs
processOne handler inbox = do
  ingested <- receive inbox
  decision <- handler ingested
  ingested.ack.finalize decision

  case decision of
    AckHalt reason -> throwIO (ProcessorHalt reason)
    _ -> pure ()
```

#### Step 4: Update Supervised to catch and handle
```haskell
-- Supervised.hs - in processStream or processMessage
case result of
  Right (AckHalt reason) -> do
    updateHalted metricsVar reason
    throwIO (ProcessorHalt reason)  -- Propagate to supervisor
  -- ...
```

#### Step 5: Update metrics state machine
Consider adding explicit `Halted` state vs reusing `Failed`:
```haskell
data ProcessorState
  = Idle
  | Processing !Int !UTCTime
  | Failed !Text !UTCTime
  | Halted !HaltReason !UTCTime  -- New
  | Stopped
```

#### Step 6: Add tests
- Test `AckHalt` stops processing
- Test correct state transition
- Test supervisor receives the halt

### Breaking Changes
- `ProcessorState` gains new constructor (if adding `Halted`)
- Behavior change: processing actually stops now

### Test Plan
1. Handler returns `AckHalt` on specific message
2. Verify no subsequent messages processed
3. Verify metrics show halted state
4. Verify supervisor is notified

---

## 1.3 Enforce or Remove Policy Types

### Problem
`Ordering` and `Concurrency` policies are defined but never used:
- `validatePolicy` is never called
- `Async` and `Ahead` concurrency modes do nothing
- `RunnerConfig` holds these but is unused

### Files to Modify
- `src/Shibuya/App.hs` - Add validation
- `src/Shibuya/Runner/Supervised.hs` - Implement concurrency modes OR
- `src/Shibuya/Policy.hs` - Simplify if removing

### Implementation Plan

Two paths: **Implement** or **Remove**. Recommend: **Validate now, implement concurrency later**.

#### Path A: Validate and Stub (Recommended)

##### Step 1: Add policy to QueueProcessor
```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: Ordering,      -- New
      concurrency :: Concurrency -- New
    } ->
    QueueProcessor es
```

##### Step 2: Validate in runApp
```haskell
runApp strategy inboxSize namedProcessors = do
  -- Validate all policies first
  let validations = map validateProcessor namedProcessors
  case sequence validations of
    Left err -> pure $ Left $ PolicyValidationError err
    Right _ -> do
      -- ... existing logic

validateProcessor (procId, QueueProcessor{ordering, concurrency}) =
  case validatePolicy ordering concurrency of
    Left err -> Left $ unProcessorId procId <> ": " <> err
    Right () -> Right ()
```

##### Step 3: Warn on unimplemented modes
```haskell
-- In runSupervised or spawnProcessors
case concurrency of
  Serial -> pure ()  -- Implemented
  Ahead n -> liftIO $ hPutStrLn stderr $
    "Warning: Ahead mode not yet implemented, using Serial"
  Async n -> liftIO $ hPutStrLn stderr $
    "Warning: Async mode not yet implemented, using Serial"
```

##### Step 4: Update documentation
Document that only `Serial` is currently implemented.

#### Path B: Remove Until Implemented

##### Step 1: Remove from Policy.hs
```haskell
-- Keep only what's used
data Concurrency = Serial
  deriving stock (Eq, Show, Generic)

-- Remove Ordering entirely, or keep as documentation
```

##### Step 2: Remove RunnerConfig.hs
This module is entirely unused.

##### Step 3: Update Core.hs exports
Remove unused policy exports.

### Recommendation
Go with **Path A** - validate policies, warn on unimplemented modes. This:
- Catches invalid configurations early
- Preserves API for future implementation
- Makes limitations explicit

### Breaking Changes
- Path A: `QueueProcessor` gains fields (breaking)
- Path B: Removes types (breaking)

### Test Plan
1. Test `StrictInOrder` + `Async` returns `PolicyValidationError`
2. Test `Unordered` + `Async` passes validation (with warning)
3. Test invalid policy doesn't start any processors

---

## 1.4 Document Actual Behavior

### Problem
Documentation describes features that aren't implemented:
- Usage guide shows backpressure configuration
- Architecture docs describe concurrent processing
- No mention of current limitations

### Files to Modify
- `docs/USAGE_GUIDE.md`
- `docs/HIGH_LEVEL_ARCHITECTURE.md`
- `docs/UNIFIED_ARCHITECTURE.md`
- `README.md` (if exists)

### Implementation Plan

#### Step 1: Add "Current Limitations" section to USAGE_GUIDE.md
```markdown
## Current Limitations

Shibuya is under active development. The following features are planned but not yet implemented:

### Concurrency Modes
Currently all processing is **serial** (one message at a time per processor).
The `Ahead` and `Async` concurrency modes are defined but not yet functional.

### Backpressure
The `inboxSize` parameter is accepted but backpressure is not yet enforced.
Fast producers may cause memory growth with slow consumers.

### Halt Semantics
`AckHalt` is recorded in metrics but does not currently stop processing.
```

#### Step 2: Update architecture docs
Add "Implementation Status" indicators:
```markdown
| Feature | Status |
|---------|--------|
| Serial Processing | Implemented |
| Metrics & Introspection | Implemented |
| NQE Supervision | Implemented |
| Backpressure | Planned |
| Async Processing | Planned |
| Halt-on-Error | Planned |
```

#### Step 3: Update code comments
Add notes in key locations:
```haskell
-- | Inbox size for backpressure.
-- NOTE: Backpressure not yet implemented. This parameter is reserved
-- for future use.
inboxSize :: Int
```

#### Step 4: Add CHANGELOG.md
Track what's implemented in each version:
```markdown
# Changelog

## 0.1.0.0 (Unreleased)

### Implemented
- Core types (MessageId, Envelope, AckDecision, etc.)
- Serial message processing
- NQE-based supervision
- Metrics collection

### Not Yet Implemented
- Backpressure (inboxSize parameter)
- Concurrent processing (Async/Ahead modes)
- Halt semantics (AckHalt)
```

### Breaking Changes
None - documentation only.

### Verification
- Review all public docs for accuracy
- Ensure no feature is claimed that doesn't work
- Add issue/PR links for planned features

---

## Implementation Order

Recommended order to implement these fixes:

1. **1.4 Document Actual Behavior** - Quick win, sets expectations
2. **1.3 Validate Policies** - Catches misconfigurations early
3. **1.2 Implement AckHalt** - Smaller scope, needed for ordered streams
4. **1.1 Implement Backpressure** - Largest change, most complex

## Estimated Scope

| Item | Complexity | Files Changed | New Tests |
|------|------------|---------------|-----------|
| 1.1 Backpressure | High | 3-4 | 3-5 |
| 1.2 AckHalt | Medium | 3 | 2-3 |
| 1.3 Policies | Medium | 2-3 | 2-3 |
| 1.4 Documentation | Low | 3-4 | 0 |
