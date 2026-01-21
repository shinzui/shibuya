-- | Supervised runner - runs processors under NQE supervision with metrics.
-- This is the production runner with introspection and control.
--
-- Architecture:
-- - Each processor runs as a child under the Master's supervisor
-- - Metrics are tracked in a TVar and registered with the Master
-- - Backpressure is provided via bounded inbox between stream and processor
module Shibuya.Runner.Supervised
  ( -- * Running with Supervision
    runSupervised,

    -- * Standalone (without Master)
    runWithMetrics,

    -- * Processor Handle
    SupervisedProcessor (..),

    -- * Introspection
    getMetrics,
    getProcessorState,
    isDone,
  )
where

import Control.Concurrent.NQE.Process (Inbox, mailboxEmpty, newBoundedInbox, receive)
import Control.Concurrent.NQE.Supervisor (addChild)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
    writeTVar,
  )
import Control.Monad (unless)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, withEffToIO, (:>))
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Handler (Handler)
import Shibuya.Prelude
import Shibuya.Runner.Ingester (runIngesterWithMetrics)
import Shibuya.Runner.Master (Master (..), MasterState (..), registerProcessor, unregisterProcessor)
import Shibuya.Runner.Metrics
  ( ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
    emptyProcessorMetrics,
    incFailed,
    incProcessed,
  )
import UnliftIO (Async, catchAny, finally)
import UnliftIO qualified as UIO

-- | Handle for a supervised processor.
-- Provides introspection into the running processor.
data SupervisedProcessor = SupervisedProcessor
  { -- | Live metrics for this processor
    metrics :: !(TVar ProcessorMetrics),
    -- | The processor's ID
    processorId :: !ProcessorId,
    -- | Whether processing is complete
    done :: !(TVar Bool),
    -- | The async handle if running under supervision
    child :: !(Maybe (Async ()))
  }

-- | Get current metrics for the processor.
getMetrics :: (IOE :> es) => SupervisedProcessor -> Eff es ProcessorMetrics
getMetrics sp = liftIO $ readTVarIO sp.metrics

-- | Get current state of the processor.
getProcessorState :: (IOE :> es) => SupervisedProcessor -> Eff es ProcessorState
getProcessorState sp = liftIO $ (.state) <$> readTVarIO sp.metrics

-- | Check if processing is done.
isDone :: (IOE :> es) => SupervisedProcessor -> Eff es Bool
isDone sp = liftIO $ readTVarIO sp.done

-- | Run a processor under the Master's supervision with metrics tracking.
--
-- Architecture:
-- 1. Creates a bounded inbox (using inboxSize for backpressure)
-- 2. Spawns ingester async (reads from adapter, sends to inbox)
-- 3. Runs processor loop (receives from inbox, calls handler)
-- 4. Registers metrics with Master, unregisters on completion
--
-- Returns immediately with a handle for introspection.
runSupervised ::
  (IOE :> es) =>
  Master ->
  -- | Inbox size (for backpressure)
  Natural ->
  -- | Processor identifier
  ProcessorId ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Message handler
  Handler es msg ->
  Eff es SupervisedProcessor
runSupervised master inboxSize procId adapter handler = do
  now <- liftIO getCurrentTime

  -- Initialize state
  let initialMetrics = emptyProcessorMetrics now
  metricsVar <- liftIO $ newTVarIO initialMetrics
  doneVar <- liftIO $ newTVarIO False

  -- Register with Master
  registerProcessor master procId metricsVar

  -- Add as supervised child using NQE's Supervisor
  -- ConcUnlift Persistent allows the runInIO function to be used in the async child
  supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    addChild master.state.supervisor $
      runInIO $
        runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler
          `finally` unregisterProcessor master procId

  -- Link so exceptions propagate to the parent
  unsafeEff_ $ UIO.link supervisedChild

  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Just supervisedChild
      }

-- | Run a processor with metrics but without Master supervision.
-- Useful for testing or simple single-processor setups.
-- This blocks until the stream is exhausted and all messages are processed.
runWithMetrics ::
  (IOE :> es) =>
  -- | Inbox size (for backpressure)
  Natural ->
  -- | Processor identifier
  ProcessorId ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Message handler
  Handler es msg ->
  Eff es SupervisedProcessor
runWithMetrics inboxSize procId adapter handler = do
  now <- liftIO getCurrentTime

  -- Initialize state
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

  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Nothing
      }

-- | Run ingester and processor with a bounded inbox.
-- Ingester reads from adapter stream, processor calls handler.
-- When stream exhausts, processor drains remaining messages and exits.
runIngesterAndProcessor ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  TVar Bool ->
  Natural ->
  Adapter es msg ->
  Handler es msg ->
  Eff es ()
runIngesterAndProcessor metricsVar doneVar inboxSize adapter handler = do
  -- Create bounded inbox (this is where inboxSize is used for backpressure)
  inbox <- liftIO $ newBoundedInbox inboxSize

  -- Signal when ingester completes (stream exhausted)
  streamDoneVar <- liftIO $ newTVarIO False

  -- Run ingester async, processor in main thread
  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    -- Ingester: run until stream exhausts, then signal done
    let ingesterWithSignal = do
          runInIO $ runIngesterWithMetrics metricsVar adapter.source inbox
          atomically $ writeTVar streamDoneVar True

    UIO.withAsync ingesterWithSignal $ \_ ->
      -- Processor: process messages, exit when stream done and inbox empty
      runInIO $ processUntilDrained metricsVar handler inbox streamDoneVar

  -- Mark done when processor exits
  liftIO $ atomically $ writeTVar doneVar True

-- | Process messages from inbox until stream is done and inbox is empty.
-- This handles both infinite streams (runs until cancelled) and
-- finite streams (drains remaining messages then exits).
processUntilDrained ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  TVar Bool ->
  Eff es ()
processUntilDrained metricsVar handler inbox streamDoneVar = go
  where
    go = do
      -- Check if we should exit: stream done AND inbox empty
      shouldExit <- liftIO $ do
        done <- readTVarIO streamDoneVar
        if done
          then mailboxEmpty inbox
          else pure False

      if shouldExit
        then pure () -- All done, exit
        else do
          -- Process one message (blocks if inbox empty but stream not done)
          processMessageFromInbox metricsVar handler inbox
          go

-- | Drain inbox until empty, with metrics tracking.
-- Used for testing with finite streams.
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

-- | Process a single message from inbox with metrics tracking.
processMessageFromInbox ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
processMessageFromInbox metricsVar handler inbox = do
  -- Receive from inbox (blocks if empty)
  ingested <- liftIO $ receive inbox

  -- Update state to Processing
  now <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    m & #state .~ Processing (m.stats.processed + 1) now

  -- Call handler and finalize
  result <-
    catchAny
      ( do
          decision <- handler ingested
          ingested.ack.finalize decision
          pure (Right decision)
      )
      (pure . Left . Text.pack . show)

  -- Update stats based on result
  case result of
    Right AckOk -> updateSuccess metricsVar
    Right (AckRetry _) -> updateSuccess metricsVar
    Right (AckDeadLetter _) -> updateFailed metricsVar
    Right (AckHalt reason) -> updateHalted metricsVar reason
    Left errMsg -> do
      now' <- liftIO getCurrentTime
      liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
        m
          { stats = incFailed m.stats,
            state = Failed errMsg now'
          }

updateSuccess :: (IOE :> es) => TVar ProcessorMetrics -> Eff es ()
updateSuccess metricsVar = liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
  m {stats = incProcessed m.stats, state = Idle}

updateFailed :: (IOE :> es) => TVar ProcessorMetrics -> Eff es ()
updateFailed metricsVar = liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
  m {stats = incFailed m.stats, state = Idle}

updateHalted :: (IOE :> es) => TVar ProcessorMetrics -> HaltReason -> Eff es ()
updateHalted metricsVar reason = do
  now <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    m & #state .~ Failed (haltReasonText reason) now
  where
    haltReasonText (HaltOrderedStream t) = t
    haltReasonText (HaltFatal t) = t
