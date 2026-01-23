# Priority 3: Code Quality

> **Note:** This is pre-release development (v0.1.0.0). Breaking changes are expected and not a concern until the first stable release.

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
  ( ShibuyaError (..),
    PolicyError (..),
    AdapterError (..),
    HandlerError (..),
    RuntimeError (..),
    errorToText,
  ) where

data ShibuyaError
  = ShibuyaPolicyError !PolicyError
  | ShibuyaAdapterError !AdapterError
  | ShibuyaHandlerError !HandlerError
  | ShibuyaRuntimeError !RuntimeError
  deriving stock (Eq, Show, Generic)

data PolicyError = InvalidPolicyCombo !Ordering !Concurrency !Text
  deriving stock (Eq, Show, Generic)

data AdapterError
  = AdapterConnectionFailed !Text
  | AdapterStreamEnded !Text
  deriving stock (Eq, Show, Generic)

data HandlerError
  = HandlerException !Text
  | HandlerTimeout
  deriving stock (Eq, Show, Generic)

data RuntimeError
  = SupervisorFailed !Text
  | InboxOverflow
  deriving stock (Eq, Show, Generic)
```

#### Step 2: Update AppError to use ShibuyaError
```haskell
type AppError = ShibuyaError
```

#### Step 3: Update validatePolicy
```haskell
validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()
```

#### Step 4: Update ProcessorState.Failed
```haskell
data ProcessorState = Failed !HandlerError !UTCTime
```

#### Step 5: Update Supervised.hs exception catching
```haskell
catchAny (\e -> pure . Left . HandlerException . Text.pack . show $ e)
```

#### Step 6: Export from Core.hs

---

## 3.2 Remove Dead Code ✅ COMPLETED

**Status:** Implemented. Removed unused `Runner.hs` module entirely.

### Summary
Removed `RunnerConfig` and `defaultRunnerConfig` which were never used by `runApp`.
The entire `Shibuya.Runner` module was deleted since it only contained this dead code.

---

## 3.3 Add Eq Instance to ProcessorMetrics ✅ COMPLETED

**Status:** Implemented. `ProcessorMetrics` now derives `Eq`.

### Summary
Added `Eq` to `ProcessorMetrics` deriving clause, enabling equality comparisons in tests.

---

## 3.4 Replace Polling with Blocking in waitApp ✅ COMPLETED

**Status:** Implemented. `waitApp` now uses STM blocking instead of polling.

### Summary
Replaced 100ms polling loop with efficient STM blocking using `check` and `retry`.

### Implementation
```haskell
waitApp :: (IOE :> es) => AppHandle es -> Eff es ()
waitApp appHandle = liftIO $ atomically $ do
  forM_ (Map.elems appHandle.processors) $ \(sp, _) ->
    readTVar sp.done >>= check
```

### Benefits
- Zero CPU usage while waiting (no busy-loop)
- Immediate wake-up when all processors complete (no 100ms latency)
- Test suite runs ~30% faster (0.6s vs 0.9s)

---

## Implementation Order

Recommended order:

1. **3.3 Add Eq to ProcessorMetrics** - One-line change
2. **3.4 Replace Polling** - Improves efficiency
3. **3.2 Remove Dead Code** - Cleanup
4. **3.1 Consolidate Errors** - Larger refactor

## Progress

| Item | Status | Complexity |
|------|--------|------------|
| 3.1 Error Handling | 🔲 Pending | High |
| 3.2 Dead Code | ✅ Done | Low |
| 3.3 Add Eq | ✅ Done | Trivial |
| 3.4 Replace Polling | ✅ Done | Low |

## Dependencies

- 3.1 (errors) can inform Priority 1.3 (policy validation) error types
