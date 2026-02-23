# Priority 3: Code Quality

> **Note:** This is pre-release development (v0.1.0.0). Breaking changes are expected and not a concern until the first stable release.

These issues affect maintainability, testability, and code cleanliness. While not user-facing, they reduce technical debt and make future development easier.

---

## 3.1 Consolidate Error Handling ✅ COMPLETED

**Status:** Implemented. Created unified error module with structured types.

### Summary
Created `Shibuya.Core.Error` module with structured error types:
- `PolicyError` - Policy validation errors
- `HandlerError` - Handler execution errors
- `RuntimeError` - Runtime/supervisor errors

Updated all error handling to use structured types:
- `validatePolicy` now returns `Either PolicyError ()`
- `AppError` uses structured constructors: `AppPolicyError`, `AppHandlerError`, `AppRuntimeError`
- `Supervised.hs` wraps exceptions in `HandlerException`

### Design Decision
`ProcessorState.Failed` still uses `Text` for simplicity (display-only). The structured
errors are converted to text at the metrics boundary. This keeps metrics simple while
providing structured errors at the API level.

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
| 3.1 Error Handling | ✅ Done | High |
| 3.2 Dead Code | ✅ Done | Low |
| 3.3 Add Eq | ✅ Done | Trivial |
| 3.4 Replace Polling | ✅ Done | Low |

All Priority 3 items have been completed.
