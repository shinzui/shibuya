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

## 3.2 Remove Dead Code

### Problem
Several modules and types are defined but never used:

| Code | Location | Issue |
|------|----------|-------|
| `RunnerConfig` | `Runner.hs` | Never used by `runApp` |
| `defaultRunnerConfig` | `Runner.hs` | Never called |

### Recommendation
Since this is pre-release, remove unused code:

1. Remove `RunnerConfig` and `defaultRunnerConfig` from `Runner.hs`
2. Remove exports from `Core.hs`
3. Update cabal if removing modules entirely

### Implementation
```bash
# Find any usage before removing
grep -r "RunnerConfig" .
grep -r "defaultRunnerConfig" .
```

---

## 3.3 Add Eq Instance to ProcessorMetrics ✅ COMPLETED

**Status:** Implemented. `ProcessorMetrics` now derives `Eq`.

### Summary
Added `Eq` to `ProcessorMetrics` deriving clause, enabling equality comparisons in tests.

---

## 3.4 Replace Polling with Blocking in waitApp

### Problem
`waitApp` uses inefficient polling:

```haskell
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

### Recommendation: Use STM retry

```haskell
waitApp :: (IOE :> es) => AppHandle es -> Eff es ()
waitApp appHandle = liftIO $ atomically $ do
  allDone <- and <$> traverse (readTVar . done . fst)
                              (Map.elems appHandle.processors)
  unless allDone retry
```

This blocks efficiently until all `done` TVars become `True`.

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

## Progress

| Item | Status | Complexity |
|------|--------|------------|
| 3.1 Error Handling | 🔲 Pending | High |
| 3.2 Dead Code | 🔲 Pending | Low |
| 3.3 Add Eq | ✅ Done | Trivial |
| 3.4 Replace Polling | 🔲 Pending | Low |

## Dependencies

- 3.1 (errors) can inform Priority 1.3 (policy validation) error types
