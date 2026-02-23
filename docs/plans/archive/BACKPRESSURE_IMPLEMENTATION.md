# Backpressure Implementation Plan

## Problem

The `inboxSize` parameter in `runApp` and `runSupervised` is documented for backpressure but has no effect. The existing `Ingester.hs` and `Processor.hs` modules implement the correct bounded inbox pattern but are never used.

**Current flow (broken):**
```
Supervised.processStream:
  Stream.fold Fold.drain $
    Stream.mapM processMessage adapter.source
```
- `inboxSize` is accepted but ignored
- No NQE inbox is used
- No backpressure beyond Streamly's natural pull-based flow

**Target flow:**
```
Adapter.source → Ingester → Bounded Inbox (inboxSize) → Processor → Handler
```
- NQE bounded inbox provides backpressure
- Ingester blocks when inbox is full
- Processor blocks when inbox is empty

## Existing Modules

### Ingester.hs (already correct)
```haskell
runIngester :: Stream (Eff es) (Ingested es msg) -> Inbox (Ingested es msg) -> Eff es ()
runIngester source inbox = do
  let mailbox = inboxToMailbox inbox
  Stream.fold Fold.drain $
    Stream.mapM (\msg -> send msg mailbox >> pure msg) source
```
- Reads from stream, sends to inbox
- Blocks on `send` when inbox full (NQE backpressure)
- Completes when stream exhausts

### Processor.hs (already correct)
```haskell
runProcessor :: Handler es msg -> Inbox (Ingested es msg) -> Eff es ()
runProcessor handler inbox = forever $ processOne handler inbox

processOne :: Handler es msg -> Inbox (Ingested es msg) -> Eff es ()
processOne handler inbox = do
  ingested <- receive inbox  -- Blocks if empty
  decision <- handler ingested
  ingested.ack.finalize decision
```
- Receives from inbox, calls handler
- Blocks on `receive` when inbox empty
- Runs forever until cancelled

## Implementation

### Step 1: Add Helper to Processor.hs

Add a function to drain remaining messages (for testing with finite streams):

```haskell
-- | Drain all remaining messages from inbox until empty.
-- Used after ingester completes to process buffered messages.
drainInbox ::
  (IOE :> es) =>
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
drainInbox handler inbox = go
  where
    go = do
      empty <- liftIO $ mailboxEmpty inbox
      unless empty $ do
        processOne handler inbox
        go
```

### Step 2: Modify Supervised.hs

Replace `processStream` with inbox-based flow:

```haskell
import Control.Concurrent.NQE.Process (newBoundedInbox, mailboxEmpty)
import Shibuya.Runner.Ingester (runIngester)

-- | Run ingester and processor with a bounded inbox.
-- For production: runs until supervisor cancels.
runIngesterAndProcessor ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  TVar Bool ->
  Natural ->
  Adapter es msg ->
  Handler es msg ->
  Eff es ()
runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler = do
  -- Create bounded inbox (this is where inboxSize is used!)
  inbox <- liftIO $ newBoundedInbox inboxSize

  -- Run ingester async, processor in main thread
  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    UIO.withAsync (runInIO $ runIngesterWithMetrics metricsVar adapter.source inbox) $ \_ ->
      runInIO $ processLoop metricsVar handler inbox

  -- Mark done when processor exits
  liftIO $ atomically $ writeTVar doneVar True

-- | Process messages from inbox with metrics tracking.
-- Runs until cancelled.
processLoop ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
processLoop metricsVar handler inbox = forever $ do
  processMessageFromInbox metricsVar handler inbox

-- | Process a single message from inbox with metrics.
processMessageFromInbox ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
processMessageFromInbox metricsVar handler inbox = do
  -- Receive (blocks if empty)
  ingested <- liftIO $ receive inbox

  -- Update state to Processing
  now <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    m & #state .~ Processing (m.stats.processed + 1) now

  -- Call handler and finalize (existing processMessage logic)
  result <- catchAny
    ( do
        decision <- handler ingested
        ingested.ack.finalize decision
        pure (Right decision)
    )
    (pure . Left . Text.pack . show)

  -- Update metrics (existing logic)
  case result of
    Right AckOk -> updateSuccess metricsVar
    Right (AckRetry _) -> updateSuccess metricsVar
    Right (AckDeadLetter _) -> updateFailed metricsVar
    Right (AckHalt reason) -> updateHalted metricsVar reason
    Left errMsg -> do
      now' <- liftIO getCurrentTime
      liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
        m { stats = incFailed m.stats, state = Failed errMsg now' }
```

Update `runSupervised`:

```haskell
runSupervised master inboxSize procId adapter handler = do
  now <- liftIO getCurrentTime
  let initialMetrics = emptyProcessorMetrics now
  metricsVar <- liftIO $ newTVarIO initialMetrics
  doneVar <- liftIO $ newTVarIO False

  registerProcessor master procId metricsVar

  supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    addChild master.state.supervisor $
      runInIO $
        runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
          `finally` unregisterProcessor master procId

  unsafeEff_ $ UIO.link supervisedChild

  pure SupervisedProcessor
    { metrics = metricsVar
    , processorId = procId
    , done = doneVar
    , child = Just supervisedChild
    }
```

Update `runWithMetrics` for testing (finite streams):

```haskell
runWithMetrics inboxSize procId adapter handler = do
  now <- liftIO getCurrentTime
  let initialMetrics = emptyProcessorMetrics now
  metricsVar <- liftIO $ newTVarIO initialMetrics
  doneVar <- liftIO $ newTVarIO False

  -- Create bounded inbox
  inbox <- liftIO $ newBoundedInbox inboxSize

  -- Run ingester to completion (all messages sent to inbox)
  runIngesterWithMetrics metricsVar adapter.source inbox

  -- Drain remaining messages from inbox
  drainInboxWithMetrics metricsVar handler inbox

  -- Mark done
  liftIO $ atomically $ writeTVar doneVar True

  pure SupervisedProcessor
    { metrics = metricsVar
    , processorId = procId
    , done = doneVar
    , child = Nothing
    }

-- | Drain inbox until empty, with metrics tracking.
drainInboxWithMetrics ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
drainInboxWithMetrics metricsVar handler inbox = go
  where
    go = do
      empty <- liftIO $ mailboxEmpty inbox
      unless empty $ do
        processMessageFromInbox metricsVar handler inbox
        go
```

### Step 3: Add Metrics to Ingester

Create `runIngesterWithMetrics` that increments `received` count:

```haskell
-- In Ingester.hs
runIngesterWithMetrics ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Stream (Eff es) (Ingested es msg) ->
  Inbox (Ingested es msg) ->
  Eff es ()
runIngesterWithMetrics metricsVar source inbox = do
  let mailbox = inboxToMailbox inbox
  Stream.fold Fold.drain $
    Stream.mapM
      ( \msg -> do
          -- Increment received count
          liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
            m {stats = incReceived m.stats}
          -- Send to inbox (blocks if full)
          liftIO $ send msg mailbox
          pure msg
      )
      source
```

## Files to Modify

| File | Changes |
|------|---------|
| `Ingester.hs` | Add `runIngesterWithMetrics` |
| `Processor.hs` | Add `drainInbox` |
| `Supervised.hs` | Replace `processStream` with inbox-based flow |

## New Imports Needed

```haskell
-- In Supervised.hs
import Control.Concurrent.NQE.Process (newBoundedInbox, mailboxEmpty, receive)
import Shibuya.Runner.Ingester (runIngesterWithMetrics)
```

## Breaking Changes

None. The API remains identical:
- `runSupervised` still accepts `inboxSize` (now actually used)
- `runWithMetrics` still accepts `inboxSize` (now actually used)
- Return types unchanged

## Test Plan

Existing tests should pass unchanged. The behavior is the same, just with proper backpressure:

1. **Existing tests**: Verify no regression
2. **Backpressure test** (optional): Create slow handler with fast producer, verify bounded memory usage

## Summary

The fix is straightforward: wire up the existing `Ingester` and `Processor` modules with a bounded inbox created via `newBoundedInbox inboxSize`. NQE and Streamly handle all the complexity of backpressure automatically.
