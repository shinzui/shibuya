# Runner Bug Fixes (v0.1.0)

This document describes three critical bugs discovered in the runner subsystem during benchmark testing, along with their root causes and fixes.

## Summary

| Bug | Location | Symptom | Severity |
|-----|----------|---------|----------|
| Incomplete `stopMaster` | `Master.hs` | Orphan threads, STM deadlocks | High |
| TOCTOU race in `inboxToStream` | `Supervised.hs` | Processor blocks forever | High |
| Missing exception safety | `Supervised.hs` | Processor blocks forever | Medium |

---

## Bug 1: Incomplete `stopMaster` Leaves Orphan Threads

### Location
`Shibuya.Runner.Master.stopMaster`

### The Bug

The original `stopMaster` implementation only cancelled the master message loop:

```haskell
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ do
  cancel (master ^. #handle)  -- Only cancels masterLoop
```

This left the NQE Supervisor and all its child threads running after `stopMaster` returned.

### Root Cause

The `Master` contains two async processes:
1. `masterLoop` - handles control messages (GetMetrics, RegisterProcessor, etc.)
2. `supervisor` - NQE Supervisor that manages child processor threads

The original code only cancelled (1), leaving (2) and all its children running as orphans.

### Symptoms

- **In benchmarks**: When running many iterations in a tight loop, old supervisor children from iteration N competed with new threads from iteration N+1 for STM resources, causing "thread blocked indefinitely in an STM transaction" errors.

- **In production**: Calling `stopMaster` followed by `startMaster` would accumulate orphan threads, leading to resource leaks and potential deadlocks.

### The Fix

Cancel the supervisor first, which triggers NQE's built-in cleanup:

```haskell
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ do
  -- Cancel the supervisor first - triggers NQE's stopAll which cancels all children
  cancel (getProcessAsync master.state.supervisor)
  -- Then cancel the master message loop
  cancel (master ^. #handle)
```

NQE's `supervisorProcess` has `finally (loop state) (stopAll state)`, so when the supervisor is cancelled, it properly cancels all children via `stopAll`.

### Why This Wasn't Caught by Tests

All existing tests used `threadDelay` after `stopMaster`, providing inadvertent settling time. The benchmarks ran iterations in a tight loop with no delays, exposing the race.

---

## Bug 2: TOCTOU Race Condition in `inboxToStream`

### Location
`Shibuya.Runner.Supervised.inboxToStream`

### The Bug

The original code had a Time-Of-Check-To-Time-Of-Use (TOCTOU) race condition:

```haskell
step _ = do
  halted <- readIORef haltRef
  case halted of
    Just _ -> pure Nothing
    Nothing -> do
      done <- readTVarIO streamDoneVar   -- Check 1: Read done flag
      empty <- mailboxEmpty inbox         -- Check 2: Check if inbox empty
      if done && empty
        then pure Nothing
        else Just . (,()) <$> receive inbox  -- Action: Block on receive
```

### Root Cause

The checks and the action are not atomic. Consider this interleaving:

1. Thread reads `done = False` (stream still producing)
2. Thread reads `empty = True` (inbox temporarily empty)
3. Ingester finishes, sets `done = True`, no more messages coming
4. Thread executes `receive inbox` — **blocks forever**

The processor will never wake up because:
- No more messages will arrive (ingester is done)
- The `done` flag was already checked and found `False`

### Symptoms

- Processor hangs indefinitely waiting for messages that will never arrive
- Only manifests under specific timing conditions (race window is small)
- More likely with fast message sources or when inbox drains quickly

### The Fix

Use atomic STM with `orElse` to combine the check and action:

```haskell
step _ = do
  halted <- readIORef haltRef
  case halted of
    Just _ -> pure Nothing
    Nothing -> do
      result <- atomically $
        -- Try to receive a message
        (Just <$> receiveSTM inbox)
          `orElse`
          -- Or check if we're done (stream exhausted AND inbox empty)
          ( do
              done <- readTVar streamDoneVar
              empty <- mailboxEmptySTM inbox
              if done && empty
                then pure Nothing
                else retry  -- Inbox empty but stream not done, wait
          )
      pure $ fmap (,()) result
```

The `orElse` pattern ensures atomicity:
- First tries to receive (succeeds if inbox non-empty)
- If inbox empty, checks if truly done
- If not done, `retry` blocks until either:
  - A message arrives in the inbox, OR
  - `streamDoneVar` changes to `True`

### Why `orElse` Works

STM's `orElse` provides composable alternatives:
1. Try left branch (`receiveSTM inbox`)
2. If left retries (inbox empty), try right branch
3. If right also retries, the whole transaction retries
4. Transaction wakes when *any* TVar it read changes

This means `retry` in the right branch will wake up when `streamDoneVar` changes, even though the left branch was waiting on the inbox.

---

## Bug 3: Missing Exception Safety for `streamDoneVar`

### Location
`Shibuya.Runner.Supervised.runIngesterAndProcessor`

### The Bug

The original code set `streamDoneVar` sequentially after the ingester:

```haskell
let ingesterWithSignal = do
      runInIO $ runIngesterWithMetrics metricsVar adapter.source inbox
      atomically $ writeTVar streamDoneVar True  -- Only runs if ingester succeeds
```

If `runIngesterWithMetrics` threw an exception, the second line would never execute.

### Root Cause

The `streamDoneVar` signals to the processor that no more messages will arrive. If this signal is never set:
- The processor keeps waiting for messages
- Even though the inbox is empty and will stay empty
- The processor blocks forever

### Symptoms

- If the adapter's source stream throws an exception, processor hangs
- No visible error (exception is in the ingester async, not propagated)
- Appears as a hang rather than a crash

### The Fix

Use `finally` to ensure the signal is always set:

```haskell
let ingesterWithSignal =
      (runInIO $ runIngesterWithMetrics metricsVar adapter.source inbox)
        `finally` atomically (writeTVar streamDoneVar True)
```

Now `streamDoneVar` is set to `True` whether the ingester:
- Completes successfully (stream exhausted normally)
- Throws an exception (stream failed)
- Is cancelled (parent cancelled the async)

### Combined with Bug 2 Fix

This fix works in conjunction with the TOCTOU fix. When the ingester fails:
1. `finally` sets `streamDoneVar = True`
2. Processor's STM transaction wakes up (was retrying on `streamDoneVar`)
3. Processor sees `done = True` and `empty = True`, exits cleanly

---

## Testing Considerations

### Why Benchmarks Found These Bugs

The bugs were discovered during benchmark testing because:

1. **Tight iteration loops**: Benchmarks run the same code thousands of times in quick succession, exposing cleanup issues that single-run tests miss.

2. **No artificial delays**: Production code often has natural delays (network I/O, database queries) that mask race conditions. Benchmarks with minimal handlers expose timing-sensitive bugs.

3. **STM contention**: Running many iterations creates many threads competing for STM resources, making deadlocks more likely.

### Recommendations for Future Testing

1. **Stress tests**: Run operations in tight loops without delays
2. **Concurrent cleanup tests**: Start/stop processors rapidly
3. **Exception injection**: Test behavior when adapters throw
4. **Property-based timing tests**: Randomize delays to catch races

---

## Related Files

- `shibuya-core/src/Shibuya/Runner/Master.hs` - Master coordinator
- `shibuya-core/src/Shibuya/Runner/Supervised.hs` - Supervised processor runner
- `shibuya-core-bench/bench/Bench/Concurrency.hs` - Benchmarks that exposed these bugs
