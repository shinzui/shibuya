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
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, withEffToIO, (:>))
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Error (HandlerError (..), handlerErrorToText)
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Prelude
import Shibuya.Runner.Halt (ProcessorHalt (..))
import Shibuya.Runner.Ingester (runIngesterWithMetrics)
import Shibuya.Runner.Master (Master (..), MasterState (..), registerProcessor, unregisterProcessor)
import Shibuya.Runner.Metrics
  ( InFlightInfo (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    emptyProcessorMetrics,
    incFailed,
    incProcessed,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Stream.Prelude qualified as StreamP
import UnliftIO (Async, catch, catchAny, finally, throwIO)
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
  -- | Concurrency mode
  Concurrency ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Message handler
  Handler es msg ->
  Eff es SupervisedProcessor
runSupervised master inboxSize procId concurrency adapter handler = do
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
        -- Catch ProcessorHalt to prevent propagation via link
        -- (Halt is intentional, not a failure - other processors should continue)
        ( runIngesterAndProcessor metricsVar doneVar inboxSize concurrency adapter handler
            `catch` \(ProcessorHalt _) -> pure () -- Convert halt to graceful exit
        )
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
  Concurrency ->
  Adapter es msg ->
  Handler es msg ->
  Eff es ()
runIngesterAndProcessor metricsVar doneVar inboxSize concurrency adapter handler = do
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
      runInIO $ processUntilDrained metricsVar concurrency handler inbox streamDoneVar

  -- Mark done when processor exits
  liftIO $ atomically $ writeTVar doneVar True

-- | Convert inbox to a stream for use with streamly.
-- Respects both the stream-done signal and halt flag.
inboxToStream ::
  Inbox (Ingested es msg) ->
  TVar Bool ->
  IORef (Maybe HaltReason) ->
  Stream.Stream IO (Ingested es msg)
inboxToStream inbox streamDoneVar haltRef = Stream.unfoldrM step ()
  where
    step _ = do
      -- Check halt flag first
      halted <- readIORef haltRef
      case halted of
        Just _ -> pure Nothing -- Stop reading
        Nothing -> do
          done <- readTVarIO streamDoneVar
          empty <- mailboxEmpty inbox
          if done && empty
            then pure Nothing
            else Just . (,()) <$> receive inbox

-- | Process messages from inbox until stream is done and inbox is empty.
-- Supports Serial, Ahead, and Async concurrency modes.
processUntilDrained ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Concurrency ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  TVar Bool ->
  Eff es ()
processUntilDrained metricsVar concurrency handler inbox streamDoneVar = do
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
          StreamP.parMapM (StreamP.maxBuffer n . StreamP.ordered True) processAction inboxStream
      Async n ->
        Stream.fold Fold.drain $
          StreamP.parMapM (StreamP.maxBuffer n) processAction inboxStream

    -- After draining, check if we halted
    maybeHalt <- readIORef haltRef
    case maybeHalt of
      Just reason -> throwIO $ ProcessorHalt reason
      Nothing -> pure ()

-- | Drain inbox until empty, with metrics tracking.
-- Used for testing with finite streams.
drainInboxWithMetrics ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
drainInboxWithMetrics metricsVar handler inbox = do
  haltRef <- liftIO $ newIORef Nothing
  go haltRef
  where
    go haltRef = do
      empty <- liftIO $ mailboxEmpty inbox
      unless empty $ do
        ingested <- liftIO $ receive inbox
        processOne metricsVar 1 haltRef handler ingested
        -- Check if halted
        halted <- liftIO $ readIORef haltRef
        case halted of
          Just reason -> throwIO $ ProcessorHalt reason
          Nothing -> go haltRef

-- | Process a single message with metrics tracking.
-- Thread-safe for concurrent execution.
processOne ::
  (IOE :> es) =>
  TVar ProcessorMetrics ->
  Int ->
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

  -- Call handler and finalize
  result <-
    catchAny
      ( do
          decision <- handler ingested
          ingested.ack.finalize decision
          pure (Right decision)
      )
      (pure . Left . HandlerException . Text.pack . show)

  -- Decrement in-flight and update stats
  now' <- liftIO getCurrentTime
  liftIO $ atomically $ modifyTVar' metricsVar $ decrementAndUpdate result now'

  -- Handle halt (set flag, don't throw - let stream drain)
  case result of
    Right (AckHalt reason) -> liftIO $ atomicWriteIORef haltRef (Just reason)
    _ -> pure ()

-- | Decrement in-flight count and update stats based on result.
decrementAndUpdate ::
  Either HandlerError AckDecision ->
  UTCTime ->
  ProcessorMetrics ->
  ProcessorMetrics
decrementAndUpdate result now m =
  let newState = case m.state of
        Processing info _ ->
          if info.inFlight <= 1
            then Idle
            else Processing (info {inFlight = info.inFlight - 1}) now
        other -> other
      newStats = case result of
        Right AckOk -> incProcessed m.stats
        Right (AckRetry _) -> incProcessed m.stats
        Right (AckDeadLetter _) -> incFailed m.stats
        Right (AckHalt _) -> m.stats -- Mark as failed with halt message
        Left _ -> incFailed m.stats
      finalState = case result of
        Right (AckHalt reason) -> Failed (haltReasonText reason) now
        Left err -> Failed (handlerErrorToText err) now
        _ -> newState
   in m {state = finalState, stats = newStats}
  where
    haltReasonText (HaltOrderedStream t) = t
    haltReasonText (HaltFatal t) = t
