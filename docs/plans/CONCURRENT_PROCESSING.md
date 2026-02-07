# Implementation Plan: Concurrent Processing (Ahead/Async)

## Overview

Add Ahead and Async concurrent processing modes to Shibuya, enabling concurrent handler execution while maintaining ordering guarantees where needed.

## Design Decisions

- **Halt behavior**: Wait for in-flight messages to complete, then halt
- **Policy validation**: Include `Ordering` in `QueueProcessor` for compile-time-adjacent validation

---

## Files to Modify

| File | Changes |
|------|---------|
| `shibuya-core/src/Shibuya/App.hs` | Extend `QueueProcessor` with `Concurrency` and `Ordering`; validate in `runApp` |
| `shibuya-core/src/Shibuya/Runner/Supervised.hs` | Implement concurrent processing with `parMapM` |
| `shibuya-core/src/Shibuya/Runner/Metrics.hs` | Extend `ProcessorState` for in-flight tracking |
| `shibuya-core/src/Shibuya/Core.hs` | Re-export new types |
| `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` | Add concurrency mode tests |
| `docs/architecture/CONCURRENCY.md` | Update as implemented |

---

## Implementation Steps

### Step 1: Extend QueueProcessor (App.hs)

```haskell
-- Add imports
import Shibuya.Policy (Concurrency(..), Ordering(..), validatePolicy)

-- Extend QueueProcessor
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: Ordering,        -- NEW
      concurrency :: Concurrency   -- NEW
    } ->
    QueueProcessor es

-- Convenience constructor (backward compatible default)
mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es
mkProcessor adapter handler = QueueProcessor adapter handler Unordered Serial
```

### Step 2: Add Policy Validation (App.hs)

In `runApp`, validate each processor's policy before spawning:

```haskell
runApp strategy inboxSize namedProcessors = do
  -- Validate all policies first
  case validateAllPolicies namedProcessors of
    Left err -> pure $ Left $ AppPolicyError err
    Right () -> do
      -- existing spawn logic...

validateAllPolicies :: [(ProcessorId, QueueProcessor es)] -> Either PolicyError ()
validateAllPolicies = traverse_ validateOne
  where
    validateOne (_, QueueProcessor _ _ ordering concurrency) =
      validatePolicy ordering concurrency
```

### Step 3: Extend Metrics (Metrics.hs)

```haskell
-- Track concurrent in-flight messages
data InFlightInfo = InFlightInfo
  { inFlight :: !Int,        -- Currently processing
    maxConcurrency :: !Int   -- Configured max (1 for Serial)
  }
  deriving stock (Eq, Show, Generic)

data ProcessorState
  = Idle
  | Processing !InFlightInfo !UTCTime  -- CHANGED from !Int
  | Failed !Text !UTCTime
  | Stopped
  deriving stock (Eq, Show, Generic)

-- Helpers for atomic updates
emptyInFlightInfo :: Int -> InFlightInfo
emptyInFlightInfo maxConc = InFlightInfo 0 maxConc
```

### Step 4: Implement Concurrent Processing (Supervised.hs)

#### 4a. Add imports

```haskell
import Streamly.Data.Stream.Prelude qualified as StreamP
import Data.IORef (IORef, newIORef, readIORef, atomicWriteIORef)
import Shibuya.Policy (Concurrency(..))
```

#### 4b. Update runSupervised signature

```haskell
runSupervised ::
  (IOE :> es) =>
  Master ->
  Natural ->        -- inboxSize
  ProcessorId ->
  Concurrency ->    -- NEW
  Adapter es msg ->
  Handler es msg ->
  Eff es SupervisedProcessor
```

#### 4c. Convert inbox to stream

```haskell
inboxToStream ::
  Inbox (Ingested es msg) ->
  TVar Bool ->        -- streamDone
  IORef (Maybe HaltReason) ->  -- halt flag
  Stream IO (Ingested es msg)
inboxToStream inbox streamDoneVar haltRef = Stream.unfoldrM step ()
  where
    step _ = do
      -- Check halt flag first
      halted <- readIORef haltRef
      case halted of
        Just _ -> pure Nothing  -- Stop reading
        Nothing -> do
          done <- readTVarIO streamDoneVar
          empty <- mailboxEmpty inbox
          if done && empty
            then pure Nothing
            else Just . (,()) <$> receive inbox
```

#### 4d. Implement concurrent processUntilDrained

```haskell
processUntilDrained ::
  (IOE :> es) =>
  Concurrency ->
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  TVar Bool ->
  Eff es ()
processUntilDrained concurrency metricsVar handler inbox streamDoneVar = do
  haltRef <- liftIO $ newIORef Nothing

  let maxConc = case concurrency of
        Serial -> 1
        Ahead n -> n
        Async n -> n

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let inboxStream = inboxToStream inbox streamDoneVar haltRef
        processAction = runInIO . processOne metricsVar maxConc haltRef handler

    case concurrency of
      Serial ->
        Stream.fold Fold.drain $
          Stream.mapM processAction inboxStream

      Ahead n ->
        Stream.fold Fold.drain $
          StreamP.parMapM (StreamP.maxBuffer n . StreamP.ordered True)
            processAction inboxStream

      Async n ->
        Stream.fold Fold.drain $
          StreamP.parMapM (StreamP.maxBuffer n)
            processAction inboxStream

    -- After draining, check if we halted
    maybeHalt <- readIORef haltRef
    case maybeHalt of
      Just reason -> throwIO $ ProcessorHalt reason
      Nothing -> pure ()
```

#### 4e. Refactor processOne for concurrent use

```haskell
processOne ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Int ->  -- maxConcurrency
  IORef (Maybe HaltReason) ->
  Handler es msg ->
  Ingested es msg ->
  Eff es ()
processOne metricsVar maxConc haltRef handler ingested = do
  -- Increment in-flight
  now <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    let current = case m.state of
          Processing info _ -> info.inFlight
          _ -> 0
    in m & #state .~ Processing (InFlightInfo (current + 1) maxConc) now

  -- Call handler
  result <- catchAny
    ( do
        decision <- handler ingested
        ingested.ack.finalize decision
        pure (Right decision)
    )
    (pure . Left . HandlerException . Text.pack . show)

  -- Decrement in-flight and update stats
  liftIO $ atomically $ modifyTVar' metricsVar $ decrementAndUpdate result

  -- Handle halt (set flag, don't throw - let stream drain)
  case result of
    Right (AckHalt reason) -> liftIO $ atomicWriteIORef haltRef (Just reason)
    _ -> pure ()

decrementAndUpdate :: Either HandlerError AckDecision -> ProcessorMetrics -> ProcessorMetrics
decrementAndUpdate result m =
  let newInFlight = case m.state of
        Processing info t ->
          if info.inFlight <= 1
            then Idle
            else Processing (info {inFlight = info.inFlight - 1}) t
        other -> other
      newStats = case result of
        Right AckOk -> incProcessed m.stats
        Right (AckRetry _) -> incProcessed m.stats
        Right (AckDeadLetter _) -> incFailed m.stats
        Right (AckHalt _) -> m.stats  -- Counted when thrown
        Left _ -> incFailed m.stats
  in m {state = newInFlight, stats = newStats}
```

### Step 5: Wire Through App.hs

Update `spawnProcessors`:

```haskell
spawnOne (procId, qp@(QueueProcessor adapter handler _ordering concurrency)) = do
  sp <- runSupervised master inboxSize procId concurrency adapter handler
  pure (procId, (sp, qp))
```

### Step 6: Update Re-exports (Core.hs)

Ensure `Ordering`, `Concurrency`, and `validatePolicy` are exported.

---

## Testing Strategy

### Unit Tests (SupervisedSpec.hs)

```haskell
describe "Concurrency modes" $ do
  describe "Ahead mode" $ do
    it "processes messages in input order despite concurrent execution"
    it "respects maxBuffer limit"
    it "handles errors without affecting other in-flight"

  describe "Async mode" $ do
    it "allows out-of-order completion"
    it "respects concurrency limit"

  describe "Halt with concurrency" $ do
    it "waits for in-flight to complete before halting"
    it "stops reading new messages after halt decision"
```

### Test Helper with Delays

```haskell
-- Handler with configurable delay
delayedHandler :: IORef [Int] -> Int -> Handler es Int
delayedHandler ref delay ingested = do
  liftIO $ threadDelay delay
  liftIO $ modifyIORef' ref (ingested.envelope.payload :)
  pure AckOk
```

---

## Verification

1. **Build**: `cabal build all`
2. **Format**: `nix fmt`
3. **Tests**: `cabal test shibuya-core-test`
4. **Specific tests**:
   - Policy validation rejects `StrictInOrder + Async`
   - Ahead mode preserves ordering
   - Async mode allows out-of-order completion
   - Halt waits for in-flight messages

---

## Implementation Order

1. Extend `ProcessorMetrics` with `InFlightInfo` (Metrics.hs)
2. Extend `QueueProcessor` with policies (App.hs)
3. Add policy validation in `runApp` (App.hs)
4. Add `inboxToStream` helper (Supervised.hs)
5. Refactor `processOne` for concurrent use (Supervised.hs)
6. Implement concurrent `processUntilDrained` (Supervised.hs)
7. Wire `Concurrency` through `runSupervised` (Supervised.hs)
8. Update `spawnProcessors` (App.hs)
9. Add tests (SupervisedSpec.hs)
10. Update documentation (CONCURRENCY.md)
