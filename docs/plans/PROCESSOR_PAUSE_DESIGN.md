# Processor Pause/Resume Design

## Overview

Add the ability to pause and resume individual processors. When paused, a processor stops consuming messages from its queue. When resumed, it picks up where it left off.

**Key design decision:** Pause at the **source stream** level, not at the inbox. This means the adapter's source stream blocks (stops yielding) while paused — no new messages are dequeued from the queue, avoiding lease/visibility timeout issues entirely.

## Motivation

- **Operational control**: Pause a processor during maintenance, backfill, or incident response without shutting it down.
- **Lease safety**: With PGMQ (or any VT-based queue), messages dequeued but unprocessed have ticking visibility timeouts. Pausing at the source avoids dequeuing messages that would expire while paused.
- **Graceful degradation**: Reduce load by selectively pausing processors without losing queue position or triggering restarts.

## Current Behavior

There is no pause mechanism. A processor runs until:
1. The adapter source stream exhausts (finite)
2. `adapter.shutdown` is called (graceful stop)
3. A handler returns `AckHalt` (halt with reason)
4. An unexpected exception propagates

The `ProcessorState` type has no `Paused` variant:
```haskell
data ProcessorState
  = Idle
  | Processing !InFlightInfo !UTCTime
  | Failed !Text !UTCTime
  | Stopped
```

The `Adapter` type has no pause capability:
```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text
  , source      :: Stream (Eff es) (Ingested es msg)
  , shutdown    :: Eff es ()
  }
```

---

## Design Decision: Where to Pause

### Option A: Inbox-level pause (rejected)

Add a `TVar Bool` check to `inboxToStream`'s STM block. When paused, the processor stops pulling from the inbox, backpressure eventually stalls the ingester.

**Problems:**
- Messages already in the bounded inbox have VTs ticking during pause
- The ingester may have already polled additional messages before backpressure kicks in
- With prefetching enabled, multiple batches may be buffered with ticking VTs
- Requires lease renewal for all buffered messages during pause

### Option B: Source-level pause via stream combinator (selected)

Wrap the adapter's `source` stream with a gate combinator. The framework creates a `TVar Bool` and inserts a blocking check between stream elements. Because Streamly is pull-based, when the gate blocks:

1. The ingester stops pulling from the gated stream
2. No new poll fires (the next `Stream.repeatM` step never executes)
3. The bounded inbox drains naturally as the processor finishes in-flight work
4. The processor goes idle

**Advantages:**
- Adapter-agnostic — works for any adapter without changes
- Zero messages dequeued while paused (at most one batch already in-flight from the current poll)
- No lease renewal needed
- Simple implementation — one combinator + one TVar

**Trade-off:** After the gate fires, up to `batchSize` messages from the current poll cycle may already be in the stream pipeline. These will be processed normally before the processor goes idle. This is acceptable — it's a partial batch, not an unbounded amount.

### Option C: Adapter-internal pause (future optimization)

Pass a `TVar Bool` into the adapter constructor so it can check *before* each poll call. This eliminates even the partial-batch trade-off from Option B.

This is left as a future optimization. The stream combinator approach is sufficient for the initial implementation and doesn't require adapter API changes.

---

## Detailed Design

### 1. Source Gate Combinator

A new stream combinator that blocks between elements when paused:

```haskell
-- | Gate a stream with a pause signal.
-- When the TVar is True (paused), blocks via STM retry until unpaused.
-- When False (running), passes elements through unchanged.
gateStream :: (IOE :> es) => TVar Bool -> Stream (Eff es) a -> Stream (Eff es) a
gateStream pauseVar = Stream.mapM $ \a -> do
  liftIO $ atomically $ do
    paused <- readTVar pauseVar
    when paused retry
  pure a
```

**How it works with `pgmqChunks`:**

```
pgmqChunks: Stream.repeatM poll  →  Vector Message
  → filter (not . null)
  → unfoldEach                   →  individual Message
  → mapMaybeM mkIngested         →  Ingested
  → gateStream pauseVar          ← GATE: blocks here when paused
  → ingester sends to inbox
```

When paused, the gate blocks after `mkIngested` produces the next element. Since Streamly is pull-based, no further `poll` calls fire until the gate unblocks and the consumer pulls again.

### 2. ProcessorState Extension

Add a `Paused` constructor:

```haskell
data ProcessorState
  = Idle
  | Processing !InFlightInfo !UTCTime
  | Paused !UTCTime                    -- NEW: paused since timestamp
  | Failed !Text !UTCTime
  | Stopped
```

With corresponding JSON serialization:

```haskell
toJSON (Paused since) =
  object
    [ "status" .= ("paused" :: Text)
    , "pausedAt" .= since
    ]

-- FromJSON:
"paused" -> Paused <$> v .: "pausedAt"
```

### 3. Pause Handle

A new type representing the pause control for a single processor:

```haskell
-- | Handle for pausing and resuming a processor.
data PauseHandle = PauseHandle
  { pauseVar :: !(TVar Bool)
  }

-- | Create a new pause handle (initially running).
newPauseHandle :: IO PauseHandle
newPauseHandle = PauseHandle <$> newTVarIO False

-- | Pause the processor. Idempotent.
pause :: PauseHandle -> IO ()
pause h = atomically $ writeTVar h.pauseVar True

-- | Resume the processor. Idempotent.
resume :: PauseHandle -> IO ()
resume h = atomically $ writeTVar h.pauseVar False

-- | Check if currently paused.
isPaused :: PauseHandle -> IO Bool
isPaused h = readTVarIO h.pauseVar
```

### 4. Integration into Supervised.hs

`runIngesterAndProcessor` creates the `PauseHandle` and gates the source stream:

```haskell
runIngesterAndProcessor metricsVar doneVar inboxSize concurrency adapter handler = do
  inbox <- liftIO $ newBoundedInbox inboxSize
  streamDoneVar <- liftIO $ newTVarIO False
  pauseHandle <- liftIO newPauseHandle                              -- NEW

  let gatedSource = gateStream pauseHandle.pauseVar adapter.source  -- NEW

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let ingesterWithSignal =
          (runInIO $ runIngesterWithMetrics metricsVar gatedSource inbox)  -- gated
            `finally` atomically (writeTVar streamDoneVar True)

    UIO.withAsync ingesterWithSignal $ \_ ->
      runInIO $ processUntilDrained metricsVar concurrency handler inbox streamDoneVar

  liftIO $ atomically $ writeTVar doneVar True
```

The `PauseHandle` needs to be returned to callers. This means threading it through `runSupervised` and into `SupervisedProcessor`:

```haskell
data SupervisedProcessor = SupervisedProcessor
  { metrics     :: !(TVar ProcessorMetrics)
  , processorId :: !ProcessorId
  , done        :: !(TVar Bool)
  , child       :: !(Maybe (Async ()))
  , pauseHandle :: !PauseHandle                -- NEW
  }
```

### 5. Metrics State Tracking

When pause/resume is triggered, the metrics state needs to update. This is done by a monitoring thread or by the pause/resume actions themselves.

**Approach:** Wrap `pause`/`resume` with metrics updates:

```haskell
-- | Pause with metrics tracking.
pauseProcessor :: SupervisedProcessor -> IO ()
pauseProcessor sp = do
  pause sp.pauseHandle
  now <- getCurrentTime
  atomically $ modifyTVar' sp.metrics $ \m ->
    m {state = Paused now}

-- | Resume with metrics tracking.
resumeProcessor :: SupervisedProcessor -> IO ()
resumeProcessor sp = do
  resume sp.pauseHandle
  atomically $ modifyTVar' sp.metrics $ \m ->
    case m.state of
      Paused _ -> m {state = Idle}
      other    -> m {state = other}  -- don't clobber Processing/Failed
```

**Note on state transitions:** When paused, the processor may still have in-flight messages being processed. The `Paused` state in metrics reflects the operator's intent ("I told it to pause"), not necessarily that all processing has ceased. In-flight messages complete naturally, and `decrementAndUpdate` continues updating stats. The state will show `Paused` until resumed, regardless of whether messages are draining.

An alternative would be to only set `Paused` after in-flight messages drain. This is more complex (requires monitoring the in-flight count) and less useful operationally — the operator wants to know "I paused it" immediately.

### 6. Public API in App.hs

Add pause/resume operations to `AppHandle`:

```haskell
-- | Pause a specific processor by ID.
-- The processor finishes any in-flight messages, then stops consuming.
-- Returns False if the processor ID is not found.
pauseAppProcessor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es Bool
pauseAppProcessor appHandle procId =
  case Map.lookup procId appHandle.processors of
    Nothing -> pure False
    Just (sp, _) -> do
      liftIO $ pauseProcessor sp
      pure True

-- | Resume a specific processor by ID.
-- Returns False if the processor ID is not found.
resumeAppProcessor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es Bool
resumeAppProcessor appHandle procId =
  case Map.lookup procId appHandle.processors of
    Nothing -> pure False
    Just (sp, _) -> do
      liftIO $ resumeProcessor sp
      pure True

-- | Check if a processor is paused.
isProcessorPaused :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es (Maybe Bool)
isProcessorPaused appHandle procId =
  case Map.lookup procId appHandle.processors of
    Nothing -> pure Nothing
    Just (sp, _) -> Just <$> liftIO (isPaused sp.pauseHandle)
```

### 7. Master Message Extension (Optional)

For remote/message-based control, extend `MasterMessage`:

```haskell
data MasterMessage
  = GetAllMetrics !(Listen MetricsMap)
  | GetProcessorMetrics !ProcessorId !(Listen (Maybe ProcessorMetrics))
  | RegisterProcessor !ProcessorId !(TVar ProcessorMetrics)
  | UnregisterProcessor !ProcessorId
  | Shutdown
  | PauseProcessor !ProcessorId !(Listen Bool)    -- NEW
  | ResumeProcessor !ProcessorId !(Listen Bool)   -- NEW
```

This is optional for the initial implementation. Direct access via `AppHandle` is sufficient. The message-based approach adds value when the Master needs to coordinate across threads or when external systems (metrics UI, HTTP API) need to control processors.

---

## Interaction with Existing Mechanisms

### Shutdown while paused

If `adapter.shutdown` or `stopAppGracefully` is called while a processor is paused:
- `adapter.shutdown` sets the shutdown TVar → `takeUntilShutdown` terminates the stream
- But the gate is blocking! The stream element that would trigger `takeUntilShutdown` never arrives.

**Fix:** Resume before shutdown, or have the gate also check the shutdown signal:

```haskell
gateStream :: (IOE :> es) => TVar Bool -> Stream (Eff es) a -> Stream (Eff es) a
gateStream pauseVar = Stream.mapM $ \a -> do
  liftIO $ atomically $ do
    paused <- readTVar pauseVar
    when paused retry
  pure a
```

The simplest fix: `stopAppGracefully` resumes all paused processors before calling `adapter.shutdown`:

```haskell
stopAppGracefully config appHandle = do
  -- Resume all paused processors so they can drain
  forM_ (Map.elems appHandle.processors) $ \(sp, _) ->
    liftIO $ resume sp.pauseHandle

  -- Then proceed with normal shutdown
  mapM_ shutdownAdapter (Map.elems appHandle.processors)
  -- ...
```

### AckHalt while paused

If the processor is paused but still draining in-flight messages, and one returns `AckHalt`:
- The halt writes to `haltRef` as normal
- `inboxToStream` checks `haltRef` before each step and stops
- The processor exits via `ProcessorHalt` exception
- The paused state becomes irrelevant (processor is done)

No special handling needed. Halt takes precedence over pause.

### Concurrent processing modes

For `Ahead` and `Async` concurrency, multiple messages may be in-flight when pause is triggered. The gate stops *new* messages from entering the pipeline, but in-flight messages complete normally. This is correct — we never interrupt a handler mid-execution.

### Prefetch interaction

With `pgmqSourceWithPrefetch`, the `parBuffered` stage eagerly evaluates future stream elements. When paused:
- The gate blocks the next element after the current one
- `parBuffered` may have already evaluated 1-2 elements ahead into its buffer
- These buffered elements will be yielded when resumed

The maximum "stranded" messages = `prefetchBufferSize * batchSize`. For the default prefetch config (buffer size 4, batch size 10), that's up to 40 messages. Their VTs are ticking.

**Mitigation for prefetch:** If this is a concern, the adapter-internal pause (Option C) can be added later to gate before `parBuffered`. For now, document the trade-off.

---

## Files Changed

| File | Change | Description |
|------|--------|-------------|
| `Shibuya/Runner/Pause.hs` | **New** | `PauseHandle`, `gateStream`, `newPauseHandle`, `pause`, `resume`, `isPaused` |
| `Shibuya/Runner/Metrics.hs` | Modify | Add `Paused !UTCTime` to `ProcessorState`, update JSON instances |
| `Shibuya/Runner/Supervised.hs` | Modify | Create `PauseHandle`, gate the source stream, add `pauseHandle` to `SupervisedProcessor`, add `pauseProcessor`/`resumeProcessor` |
| `Shibuya/App.hs` | Modify | Add `pauseAppProcessor`, `resumeAppProcessor`, `isProcessorPaused`; resume before shutdown |
| `Shibuya/Core.hs` | Modify | Re-export `PauseHandle` and pause API |
| Tests | **New** | Pause/resume tests |

---

## Testing Plan

### Test 1: Pause stops message consumption

```haskell
test "pausing stops message consumption" $ do
  processedRef <- newIORef (0 :: Int)
  gate <- newEmptyMVar

  let handler _ingested = do
        liftIO $ atomicModifyIORef' processedRef (\n -> (n + 1, ()))
        liftIO $ tryPutMVar gate ()  -- signal after each message
        pure AckOk

  -- Create adapter with many messages
  adapter <- listAdapter <$> makeMessages 100

  sp <- runWithMetricsAndPause 10 (ProcessorId "test") Serial adapter handler

  -- Let some messages process
  replicateM_ 5 (takeMVar gate)

  -- Pause
  pauseProcessor sp

  -- Record count at pause time
  threadDelay 100_000  -- let in-flight drain
  countAtPause <- readIORef processedRef

  -- Wait and verify no more processing
  threadDelay 500_000
  countAfterWait <- readIORef processedRef
  countAfterWait `shouldBe` countAtPause

  -- Resume and verify processing continues
  resumeProcessor sp
  replicateM_ 5 (takeMVar gate)
  countAfterResume <- readIORef processedRef
  countAfterResume `shouldSatisfy` (> countAtPause)
```

### Test 2: Metrics reflect paused state

```haskell
test "metrics show Paused state" $ do
  let handler _ = pure AckOk
  adapter <- listAdapter <$> makeMessages 100
  sp <- runWithMetricsAndPause 10 (ProcessorId "test") Serial adapter handler

  pauseProcessor sp
  metrics <- getMetrics sp
  case metrics.state of
    Paused _ -> pure ()
    other -> expectationFailure $ "Expected Paused, got: " <> show other

  resumeProcessor sp
  threadDelay 100_000
  metrics' <- getMetrics sp
  metrics'.state `shouldNotSatisfy` isPaused
```

### Test 3: Pause is per-processor

```haskell
test "pausing one processor doesn't affect others" $ do
  countA <- newIORef (0 :: Int)
  countB <- newIORef (0 :: Int)

  let handlerA _ = do
        liftIO $ atomicModifyIORef' countA (\n -> (n + 1, ()))
        pure AckOk
      handlerB _ = do
        liftIO $ atomicModifyIORef' countB (\n -> (n + 1, ()))
        pure AckOk

  -- Start two processors
  spA <- startProcessor "A" handlerA
  spB <- startProcessor "B" handlerB

  -- Pause only A
  pauseProcessor spA

  threadDelay 500_000

  a <- readIORef countA
  b <- readIORef countB

  -- A should have stopped, B should have continued
  a' <- readIORef countA
  b' <- readIORef countB
  a' `shouldBe` a     -- A didn't advance
  b' `shouldSatisfy` (> b)  -- B kept going
```

### Test 4: Shutdown while paused

```haskell
test "graceful shutdown works while paused" $ do
  let handler _ = pure AckOk
  appHandle <- startApp [("test", makeProcessor handler)]

  pauseAppProcessor appHandle (ProcessorId "test")
  stopAppGracefully defaultShutdownConfig appHandle
  -- Should complete without hanging
```

### Test 5: Pause idempotency

```haskell
test "double pause and double resume are idempotent" $ do
  sp <- startProcessor "test" (\_ -> pure AckOk)

  -- Double pause
  pauseProcessor sp
  pauseProcessor sp
  isPaused sp.pauseHandle `shouldReturn` True

  -- Double resume
  resumeProcessor sp
  resumeProcessor sp
  isPaused sp.pauseHandle `shouldReturn` False
```

### Test 6: In-flight messages complete during pause

```haskell
test "in-flight messages complete after pause" $ do
  startedRef <- newIORef (0 :: Int)
  completedRef <- newIORef (0 :: Int)
  slowGate <- newEmptyMVar

  let handler _ = do
        liftIO $ atomicModifyIORef' startedRef (\n -> (n + 1, ()))
        liftIO $ takeMVar slowGate  -- block until released
        liftIO $ atomicModifyIORef' completedRef (\n -> (n + 1, ()))
        pure AckOk

  sp <- startProcessor "test" handler

  -- Let one message start processing
  threadDelay 100_000
  started <- readIORef startedRef
  started `shouldBe` 1

  -- Pause while message is in-flight
  pauseProcessor sp

  -- Release the in-flight message
  putMVar slowGate ()
  threadDelay 100_000

  -- It should have completed
  completed <- readIORef completedRef
  completed `shouldBe` 1
```

---

## Implementation Checklist

- [ ] Create `Shibuya/Runner/Pause.hs`
  - [ ] `PauseHandle` type
  - [ ] `newPauseHandle`, `pause`, `resume`, `isPaused`
  - [ ] `gateStream` combinator
- [ ] Update `Shibuya/Runner/Metrics.hs`
  - [ ] Add `Paused !UTCTime` to `ProcessorState`
  - [ ] Update `ToJSON` / `FromJSON` instances
- [ ] Update `Shibuya/Runner/Supervised.hs`
  - [ ] Add `pauseHandle` to `SupervisedProcessor`
  - [ ] Create `PauseHandle` in `runIngesterAndProcessor`
  - [ ] Gate the source stream with `gateStream`
  - [ ] Thread `PauseHandle` through `runSupervised`
  - [ ] Add `pauseProcessor` / `resumeProcessor` with metrics tracking
- [ ] Update `Shibuya/App.hs`
  - [ ] Add `pauseAppProcessor`, `resumeAppProcessor`, `isProcessorPaused`
  - [ ] Resume all paused processors in `stopAppGracefully`
  - [ ] Export new functions
- [ ] Update `Shibuya/Core.hs` re-exports
- [ ] Add tests
  - [ ] Pause stops consumption
  - [ ] Metrics reflect paused state
  - [ ] Per-processor isolation
  - [ ] Shutdown while paused
  - [ ] Idempotency
  - [ ] In-flight completion
- [ ] Update `docs/architecture/` with pause semantics

---

## Future Work

- **Adapter-internal pause (Option C):** For adapters with prefetch, gate before `parBuffered` to eliminate stranded messages. Extend `Adapter` with optional `pause`/`resume` fields.
- **Master message-based control:** Add `PauseProcessor`/`ResumeProcessor` to `MasterMessage` for remote control via the Master actor.
- **Metrics UI integration:** Expose pause/resume controls in the planned WebSocket metrics UI.
- **Pause with drain:** A variant that waits for the inbox to drain before confirming pause, useful for "pause and I want to know when it's truly quiescent."
- **Pause timeout:** Auto-resume after a configurable duration, useful for temporary rate limiting.

---

## Breaking Changes

### ProcessorState

Adding `Paused !UTCTime` to `ProcessorState` is a breaking change for exhaustive pattern matches. Downstream code matching on `ProcessorState` will get a compiler warning.

**Migration:**
```haskell
-- Before:
case state of
  Idle -> ...
  Processing info t -> ...
  Failed msg t -> ...
  Stopped -> ...

-- After:
case state of
  Idle -> ...
  Processing info t -> ...
  Paused since -> ...    -- NEW
  Failed msg t -> ...
  Stopped -> ...
```

### SupervisedProcessor

Adding `pauseHandle` to `SupervisedProcessor` is a breaking change for code that constructs this record directly. In practice, only framework code creates `SupervisedProcessor` values.

### App.hs API

New functions are additive, no breaking changes.
