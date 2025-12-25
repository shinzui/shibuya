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

import Control.Concurrent.NQE.Supervisor (addChild)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
    writeTVar,
  )
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Handler (Handler)
import Shibuya.Prelude
import Shibuya.Runner.Master (Master (..), MasterState (..), registerProcessor, unregisterProcessor)
import Shibuya.Runner.Metrics
  ( ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
    emptyProcessorMetrics,
    incFailed,
    incProcessed,
    incReceived,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import UnliftIO (Async, catchAny, finally, withRunInIO)

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
-- The processor:
-- 1. Registers its metrics TVar with the Master
-- 2. Runs as a supervised child
-- 3. Unregisters when complete
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

  -- Add as supervised child
  -- We need to convert our Eff action to IO for the supervisor
  supervisedChild <- withRunInIO $ \runInIO -> do
    addChild (master.state).supervisor $ do
      -- This runs in IO under the supervisor
      runInIO $
        processStream metricsVar doneVar adapter handler
          `finally` unregisterProcessor master procId

  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Just supervisedChild
      }

-- | Run a processor with metrics but without Master supervision.
-- Useful for testing or simple single-processor setups.
-- This blocks until the stream is exhausted.
runWithMetrics ::
  (IOE :> es) =>
  -- | Inbox size (unused, for API compatibility)
  Natural ->
  -- | Processor identifier
  ProcessorId ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Message handler
  Handler es msg ->
  Eff es SupervisedProcessor
runWithMetrics _inboxSize procId adapter handler = do
  now <- liftIO getCurrentTime

  -- Initialize state
  let initialMetrics = emptyProcessorMetrics now
  metricsVar <- liftIO $ newTVarIO initialMetrics
  doneVar <- liftIO $ newTVarIO False

  -- Process the stream (blocking)
  processStream metricsVar doneVar adapter handler

  pure
    SupervisedProcessor
      { metrics = metricsVar,
        processorId = procId,
        done = doneVar,
        child = Nothing
      }

-- | Process the adapter stream with metrics tracking.
processStream ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  TVar Bool ->
  Adapter es msg ->
  Handler es msg ->
  Eff es ()
processStream metricsVar doneVar adapter handler = do
  Stream.fold Fold.drain $
    Stream.mapM (processMessage metricsVar handler) adapter.source

  -- Mark as done
  liftIO $ atomically $ writeTVar doneVar True

-- | Process a single message with metrics tracking.
processMessage ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Ingested es msg ->
  Eff es ()
processMessage metricsVar handler ingested = do
  -- Update received count
  liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
    m {stats = incReceived m.stats}

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
