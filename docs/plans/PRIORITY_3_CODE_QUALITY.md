# Priority 3: Code Quality

These issues affect maintainability, testability, and code cleanliness. While not user-facing, they reduce technical debt and make future development easier.

---

## 3.1 Consolidate Error Handling

### Problem
Errors are represented inconsistently across the codebase:

| Location | Error Representation |
|----------|---------------------|
| `App.hs` | `AppError` sum type |
| `Policy.hs` | `Either Text ()` |
| `Metrics.hs` | `Failed Text UTCTime` (plain text) |
| `Supervised.hs` | Catches exceptions → `Text` |

This makes error handling unpredictable and loses structured information.

### Files to Modify
- `src/Shibuya/Core/Error.hs` (new)
- `src/Shibuya/App.hs`
- `src/Shibuya/Policy.hs`
- `src/Shibuya/Runner/Metrics.hs`
- `src/Shibuya/Runner/Supervised.hs`

### Implementation Plan

#### Step 1: Create unified error module
```haskell
-- New file: src/Shibuya/Core/Error.hs
module Shibuya.Core.Error
  ( -- * Application Errors
    ShibuyaError (..),

    -- * Error Categories
    PolicyError (..),
    AdapterError (..),
    HandlerError (..),
    RuntimeError (..),

    -- * Utilities
    errorToText,
  ) where

-- | Top-level error type for Shibuya operations.
data ShibuyaError
  = ShibuyaPolicyError !PolicyError
  | ShibuyaAdapterError !AdapterError
  | ShibuyaHandlerError !HandlerError
  | ShibuyaRuntimeError !RuntimeError
  deriving stock (Eq, Show, Generic)

-- | Policy validation errors.
data PolicyError
  = InvalidPolicyCombo !Ordering !Concurrency !Text
  deriving stock (Eq, Show, Generic)

-- | Adapter-related errors.
data AdapterError
  = AdapterConnectionFailed !Text
  | AdapterStreamEnded !Text
  deriving stock (Eq, Show, Generic)

-- | Handler execution errors.
data HandlerError
  = HandlerException !Text  -- Caught exception
  | HandlerTimeout          -- Future: timeout support
  deriving stock (Eq, Show, Generic)

-- | Runtime/infrastructure errors.
data RuntimeError
  = SupervisorFailed !Text
  | InboxOverflow
  deriving stock (Eq, Show, Generic)

-- | Convert error to human-readable text.
errorToText :: ShibuyaError -> Text
errorToText = \case
  ShibuyaPolicyError (InvalidPolicyCombo ord conc msg) ->
    "Invalid policy: " <> msg
  ShibuyaAdapterError (AdapterConnectionFailed msg) ->
    "Adapter connection failed: " <> msg
  -- ... etc
```

#### Step 2: Update AppError to use ShibuyaError
```haskell
-- Option A: Replace AppError with ShibuyaError
-- Option B: Keep AppError as alias
type AppError = ShibuyaError

-- Or keep AppError and convert internally
data AppError = AppError !ShibuyaError
  deriving stock (Eq, Show)
```

#### Step 3: Update validatePolicy
```haskell
-- Old
validatePolicy :: Ordering -> Concurrency -> Either Text ()

-- New
validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()
validatePolicy StrictInOrder (Ahead n) =
  Left $ InvalidPolicyCombo StrictInOrder (Ahead n)
    "StrictInOrder requires Serial concurrency"
-- ...
```

#### Step 4: Update ProcessorState.Failed
```haskell
-- Old
data ProcessorState
  = Failed !Text !UTCTime

-- New
data ProcessorState
  = Failed !HandlerError !UTCTime
  -- Or keep Text but document it's from errorToText
```

#### Step 5: Update Supervised.hs exception catching
```haskell
-- Old
catchAny
  (\e -> pure . Left . Text.pack . show $ e)

-- New
catchAny
  (\e -> pure . Left . HandlerException . Text.pack . show $ e)
```

#### Step 6: Export from Core.hs
```haskell
module Shibuya.Core
  ( -- * Errors
    ShibuyaError (..),
    PolicyError (..),
    -- ... or just re-export the module
  )
```

### Breaking Changes
- `AppError` type changes (if replacing)
- `ProcessorState.Failed` field type changes
- `validatePolicy` return type changes

### Recommendation
Start with **internal consolidation** (Steps 1, 5) without changing public types. Then migrate public types in a breaking release.

---

## 3.2 Remove Dead Code

### Problem
Several modules and types are defined but never used in the execution path:

| Code | Location | Issue |
|------|----------|-------|
| `RunnerConfig` | `Runner.hs` | Never used by `runApp` |
| `defaultRunnerConfig` | `Runner.hs` | Never called |
| `runSerial` | `Runner/Serial.hs` | Not integrated |
| `runProcessor` | `Runner/Processor.hs` | Not used (Supervised has own) |
| `runIngester` | `Runner/Ingester.hs` | Not used (backpressure not impl) |

### Files to Modify
- `src/Shibuya/Runner.hs` - Remove or mark deprecated
- `src/Shibuya/Runner/Serial.hs` - Remove or integrate
- `src/Shibuya/Core.hs` - Remove unused exports
- `shibuya-core.cabal` - Update module list

### Implementation Plan

#### Decision: Remove or Keep for Future?

**Candidates for removal:**
- `RunnerConfig` - Superseded by `QueueProcessor`
- `defaultRunnerConfig` - Goes with `RunnerConfig`

**Candidates to keep (for backpressure implementation):**
- `Ingester.hs` - Needed for Priority 1.1
- `Processor.hs` - May be useful for Priority 1.1

**Candidates to evaluate:**
- `Serial.hs` - Useful as simple alternative? Or redundant?

#### Step 1: Evaluate Serial.hs usefulness

Questions:
- Is there a use case for `runSerial` vs `runWithMetrics`?
- Does `runSerial` offer any advantage (simpler, less overhead)?

If no clear use case → remove.
If useful → document when to use it.

#### Step 2: Remove RunnerConfig (if decided)

```haskell
-- Delete from Runner.hs:
data RunnerConfig es msg = RunnerConfig { ... }
defaultRunnerConfig :: ...

-- Or deprecate:
{-# DEPRECATED RunnerConfig "Use QueueProcessor instead" #-}
{-# DEPRECATED defaultRunnerConfig "Use QueueProcessor instead" #-}
```

#### Step 3: Update Core.hs exports
```haskell
-- Remove:
import Shibuya.Runner (RunnerConfig (..), defaultRunnerConfig)

-- Keep only what's used
```

#### Step 4: Update cabal if removing modules entirely
```cabal
-- If removing Serial.hs entirely:
-- Remove from exposed-modules or other-modules
```

#### Step 5: Search for any external usage
```bash
# Check if anything imports the removed code
grep -r "RunnerConfig" .
grep -r "defaultRunnerConfig" .
grep -r "runSerial" .
```

### Recommendation

**Immediate:**
- Deprecate `RunnerConfig` and `defaultRunnerConfig` (don't remove yet)
- Move `Serial.hs` to internal (already covered in 2.1)
- Keep `Ingester.hs` and `Processor.hs` for backpressure work

**Next breaking release:**
- Remove deprecated code

### Breaking Changes
- Removing `RunnerConfig` breaks code that uses it
- Deprecation warnings are non-breaking

---

## 3.3 Add Eq Instance to ProcessorMetrics

### Problem
`ProcessorMetrics` has `Show` but not `Eq`, making testing difficult:

```haskell
-- Metrics.hs:64-72
data ProcessorMetrics = ProcessorMetrics
  { state :: !ProcessorState,
    stats :: !StreamStats,
    startedAt :: !UTCTime
  }
  deriving stock (Show, Generic)  -- No Eq!
```

Tests must compare fields individually or use `show`:
```haskell
-- Awkward
finalMetrics.stats.received `shouldBe` 3
finalMetrics.stats.processed `shouldBe` 3
finalMetrics.state `shouldBe` Idle

-- Would be nicer
finalMetrics `shouldBe` expectedMetrics
```

### Files to Modify
- `src/Shibuya/Runner/Metrics.hs`

### Implementation Plan

#### Step 1: Add Eq to ProcessorMetrics
```haskell
data ProcessorMetrics = ProcessorMetrics
  { state :: !ProcessorState,
    stats :: !StreamStats,
    startedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)  -- Add Eq
```

#### Step 2: Verify all nested types have Eq

Check that these already have `Eq`:
- `ProcessorState` - Yes (line 44)
- `StreamStats` - Yes (line 57)
- `UTCTime` - Yes (from `time` library)

#### Step 3: Update tests to use direct comparison (optional)
```haskell
-- Can now do:
let expected = ProcessorMetrics
      { state = Idle
      , stats = StreamStats 3 0 3 0
      , startedAt = testTime
      }
finalMetrics `shouldBe` expected
```

Note: `startedAt` comparison may be tricky in tests if time isn't controlled. Consider:
```haskell
-- Compare only relevant fields
finalMetrics.state `shouldBe` Idle
finalMetrics.stats `shouldBe` StreamStats 3 0 3 0
-- Or use a custom matcher that ignores startedAt
```

### Breaking Changes
None - adding instance is backwards compatible.

### Bonus: Add Eq to other types without it
Audit all types for missing `Eq`:
- `Master` - Probably shouldn't have Eq (contains Async, TVar)
- `SupervisedProcessor` - Same
- `AppHandle` - Same

Only add `Eq` to pure data types, not types containing mutable references.

---

## 3.4 Replace Polling with Blocking in waitApp

### Problem
`waitApp` uses inefficient polling:

```haskell
-- App.hs:157-169
waitApp appHandle = waitAll (Map.elems appHandle.processors)
  where
    waitAll [] = pure ()
    waitAll procs = do
      allDone <- and <$> traverse (\(sp, _) -> isDone sp) procs
      if allDone
        then pure ()
        else do
          liftIO $ threadDelay 100000  -- 100ms polling
          waitAll procs
```

This wastes CPU cycles and adds latency (up to 100ms after completion).

### Files to Modify
- `src/Shibuya/App.hs`
- `src/Shibuya/Runner/Supervised.hs` (if adding blocking primitive)

### Implementation Plan

#### Option A: Use Async.wait (Simplest)

If each processor has an `Async` handle, wait on all of them:

```haskell
waitApp :: (IOE :> es) => AppHandle es -> Eff es ()
waitApp appHandle = liftIO $ do
  -- Get all async handles
  let asyncs = mapMaybe (child . fst) $ Map.elems appHandle.processors
  -- Wait for all to complete
  mapM_ Async.wait asyncs
```

Problem: This throws if any async throws. May need `waitCatch`.

#### Option B: Use STM with retry

##### Step 1: Add completion signal to SupervisedProcessor
```haskell
-- Supervised.hs
data SupervisedProcessor = SupervisedProcessor
  { metrics :: !(TVar ProcessorMetrics),
    processorId :: !ProcessorId,
    done :: !(TVar Bool),
    child :: !(Maybe (Async ()))
  }

-- Add blocking wait function
waitProcessor :: (IOE :> es) => SupervisedProcessor -> Eff es ()
waitProcessor sp = liftIO $ atomically $ do
  isDone <- readTVar sp.done
  unless isDone retry  -- Block until done becomes True
```

##### Step 2: Update waitApp to use STM
```haskell
waitApp :: (IOE :> es) => AppHandle es -> Eff es ()
waitApp appHandle = liftIO $ atomically $ do
  -- Check all processors are done
  allDone <- and <$> traverse (readTVar . done . fst)
                              (Map.elems appHandle.processors)
  unless allDone retry
```

This blocks efficiently until all `done` TVars become `True`.

#### Option C: Use MVar as completion signal

##### Step 1: Add MVar to SupervisedProcessor
```haskell
data SupervisedProcessor = SupervisedProcessor
  { ...
    completion :: !(MVar ())  -- Filled when done
  }
```

##### Step 2: Fill MVar when processing completes
```haskell
processStream metricsVar doneVar completionVar adapter handler = do
  Stream.fold Fold.drain $
    Stream.mapM (processMessage metricsVar handler) adapter.source
  liftIO $ atomically $ writeTVar doneVar True
  liftIO $ putMVar completionVar ()  -- Signal completion
```

##### Step 3: Wait on all MVars
```haskell
waitApp appHandle = liftIO $
  mapM_ (takeMVar . completion . fst) (Map.elems appHandle.processors)
```

### Recommendation
**Option B (STM retry)** is cleanest:
- No additional state needed (reuses `done` TVar)
- Efficient blocking
- Handles multiple processors naturally
- Already using STM extensively

### Breaking Changes
None - internal implementation change.

### Test Plan
1. Verify `waitApp` returns immediately when all processors done
2. Verify `waitApp` blocks until last processor completes
3. Verify no busy-waiting (check CPU usage)

---

## Implementation Order

Recommended order:

1. **3.3 Add Eq to ProcessorMetrics** - One-line change
2. **3.4 Replace Polling** - Improves efficiency
3. **3.2 Remove Dead Code** - Cleanup
4. **3.1 Consolidate Errors** - Larger refactor

## Estimated Scope

| Item | Complexity | Files Changed | Breaking |
|------|------------|---------------|----------|
| 3.1 Error Handling | High | 5-6 | Maybe |
| 3.2 Dead Code | Low | 3-4 | Maybe |
| 3.3 Add Eq | Trivial | 1 | No |
| 3.4 Replace Polling | Low | 1-2 | No |

## Dependencies

- 3.2 (dead code) should wait until after Priority 1.1 (backpressure) to know which modules are needed
- 3.1 (errors) can inform Priority 1.3 (policy validation) error types

## Testing Improvements

After these changes, consider adding:

1. **Property tests for metrics counters**
   ```haskell
   prop_metricsCountersAccurate :: [AckDecision] -> Property
   prop_metricsCountersAccurate decisions =
     let expectedProcessed = length $ filter (== AckOk) decisions
         expectedFailed = length $ filter isFailure decisions
     in ...
   ```

2. **Benchmark for waitApp**
   ```haskell
   -- Verify no busy-waiting
   benchmark "waitApp overhead" $ do
     -- Start processor with 0 messages
     -- Time how long waitApp takes
     -- Should be < 1ms, not 100ms
   ```

3. **Error round-trip tests**
   ```haskell
   prop_errorShowRead :: ShibuyaError -> Property
   prop_errorShowRead err = read (show err) === err
   ```
