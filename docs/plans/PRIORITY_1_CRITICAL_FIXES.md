# Priority 1: Critical Fixes (API/Behavior Mismatch)

These issues represent gaps between documented/expected behavior and actual implementation. Users relying on advertised features will experience unexpected behavior.

---

## 1.1 Implement Backpressure ✅ COMPLETED

**Status:** Implemented in commit `31427e2`

### Summary
Backpressure is now implemented via NQE's bounded inbox. The `inboxSize` parameter in `runSupervised` and `runWithMetrics` controls the inbox capacity.

### Architecture
```
Adapter.source → Ingester (async) → Bounded Inbox → Processor → Handler
```

### Key Changes
- `Supervised.hs`: Uses `newBoundedInbox inboxSize` to create bounded channel
- `Ingester.hs`: Added `runIngesterWithMetrics` to track received count
- `Processor.hs`: Added `drainInbox` for processing remaining messages after stream exhausts

### Behavior
- **Blocking backpressure**: When inbox is full, ingester blocks until space is available
- **Graceful shutdown**: Processor drains remaining messages when stream completes
- **Metrics tracking**: `received` incremented by ingester, `processed`/`failed` by processor

---

## 1.2 Implement AckHalt ✅ COMPLETED

**Status:** Implemented using exception-based approach with halt isolation.

### Summary
`AckHalt` now properly stops processing. When a handler returns `AckHalt`, only that processor stops while other processors continue running independently.

### Architecture
- **Exception-based signaling**: `ProcessorHalt` exception thrown on `AckHalt`
- **Halt isolation**: `runSupervised` catches `ProcessorHalt` to prevent propagation via `link`
- **Metrics update**: State set to `Failed` with halt reason text before stopping

### Key Changes
- `Halt.hs` (new): Defines `ProcessorHalt` exception type
- `Supervised.hs`: Throws `ProcessorHalt` after updating metrics; catches for halt isolation
- `Processor.hs`: Removed TODO comment, cleaned up unused import

### Behavior
- **Halt stops processing**: Handler returning `AckHalt` terminates that processor
- **Halt isolation**: Other processors continue unaffected
- **Unexpected exceptions propagate**: Bugs/resource errors still propagate via `link`
- **Metrics reflect state**: Processor state shows `Failed` with halt reason

### Tests Added
- `stops processing when handler returns AckHalt`
- `updates metrics to halted state on AckHalt`
- `halt in one supervised processor doesn't affect others`

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

Recommended order to implement remaining fixes:

1. **1.4 Document Actual Behavior** - Quick win, sets expectations
2. **1.3 Validate Policies** - Catches misconfigurations early

## Progress

| Item | Status | Complexity | Notes |
|------|--------|------------|-------|
| 1.1 Backpressure | ✅ Done | High | Commit `31427e2` |
| 1.2 AckHalt | ✅ Done | Medium | See `ACKHALT_IMPLEMENTATION.md` |
| 1.3 Policies | 🔲 Pending | Medium | |
| 1.4 Documentation | 🔲 Pending | Low | |
