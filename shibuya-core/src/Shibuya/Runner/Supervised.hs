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

import Control.Concurrent.NQE.Process (Inbox, mailboxEmpty, mailboxEmptySTM, newBoundedInbox, receive, receiveSTM)
import Control.Concurrent.NQE.Supervisor (addChild)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    orElse,
    readTVar,
    readTVarIO,
    retry,
    writeTVar,
  )
import Control.Monad (unless)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, withEffToIO, (:>))
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Error (HandlerError (..), handlerErrorToText)
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
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
import Shibuya.Telemetry.Effect
  ( Tracing,
    addAttribute,
    addEvent,
    recordException,
    setStatus,
    withExtractedContext,
    withSpan',
  )
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic
  ( attrMessagingDestinationPartitionId,
    attrMessagingMessageId,
    attrMessagingSystem,
    attrShibuyaAckDecision,
    attrShibuyaInflightCount,
    attrShibuyaInflightMax,
    consumerSpanArgs,
    eventAckDecision,
    eventHandlerCompleted,
    eventHandlerException,
    eventHandlerStarted,
    mkEvent,
    processMessageSpanName,
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
  (IOE :> es, Tracing :> es) =>
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
  (IOE :> es, Tracing :> es) =>
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
  (IOE :> es, Tracing :> es) =>
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
    -- Use finally to ensure streamDoneVar is always set, even if ingester fails
    let ingesterWithSignal =
          (runInIO $ runIngesterWithMetrics metricsVar adapter.source inbox)
            `finally` atomically (writeTVar streamDoneVar True)

    UIO.withAsync ingesterWithSignal $ \_ ->
      -- Processor: process messages, exit when stream done and inbox empty
      runInIO $ processUntilDrained metricsVar concurrency handler inbox streamDoneVar

  -- Mark done when processor exits
  liftIO $ atomically $ writeTVar doneVar True

-- | Convert inbox to a stream for use with streamly.
-- Respects both the stream-done signal and halt flag.
--
-- Uses STM to atomically check done/empty and receive, avoiding a race
-- condition where the processor could block on receive after the stream
-- has completed but before the done flag was checked.
inboxToStream ::
  Inbox (Ingested es msg) ->
  TVar Bool ->
  IORef (Maybe HaltReason) ->
  Stream.Stream IO (Ingested es msg)
inboxToStream inbox streamDoneVar haltRef = Stream.unfoldrM step ()
  where
    step _ = do
      -- Check halt flag first (outside STM since it's an IORef)
      halted <- readIORef haltRef
      case halted of
        Just _ -> pure Nothing -- Stop reading
        Nothing -> do
          -- Atomically either receive a message or detect completion.
          -- This avoids TOCTOU race where we check done/empty separately
          -- and then block on receive after the stream has completed.
          result <-
            atomically $
              -- Try to receive a message
              (Just <$> receiveSTM inbox)
                `orElse`
                -- Or check if we're done (stream exhausted and inbox empty)
                ( do
                    done <- readTVar streamDoneVar
                    empty <- mailboxEmptySTM inbox
                    if done && empty
                      then pure Nothing
                      else retry -- Inbox empty but stream not done, wait for message
                )
          pure $ fmap (,()) result

-- | Process messages from inbox until stream is done and inbox is empty.
-- Supports Serial, Ahead, and Async concurrency modes.
processUntilDrained ::
  (IOE :> es, Tracing :> es) =>
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
  (IOE :> es, Tracing :> es) =>
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

-- | Process a single message with metrics tracking and tracing.
-- Thread-safe for concurrent execution.
processOne ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  Int ->
  IORef (Maybe HaltReason) ->
  Handler es msg ->
  Ingested es msg ->
  Eff es ()
processOne metricsVar maxConc haltRef handler ingested = do
  -- Extract parent context from message headers for distributed tracing
  let parentCtx = ingested.envelope.traceContext >>= extractTraceContext

  withExtractedContext parentCtx $
    withSpan' processMessageSpanName consumerSpanArgs $ \traceSpan -> do
      -- Add messaging attributes
      let MessageId msgIdText = ingested.envelope.messageId
      addAttribute traceSpan attrMessagingSystem ("shibuya" :: Text)
      addAttribute traceSpan attrMessagingMessageId msgIdText

      -- Add partition if present
      case ingested.envelope.partition of
        Just p -> addAttribute traceSpan attrMessagingDestinationPartitionId p
        Nothing -> pure ()

      -- Increment in-flight and add inflight attributes
      now <- liftIO getCurrentTime
      currentInflight <- liftIO $ atomically $ do
        modifyTVar' metricsVar $ \m ->
          let current = case m.state of
                Processing info _ -> info.inFlight
                _ -> 0
           in m & #state .~ Processing (InFlightInfo (current + 1) maxConc) now
        m <- readTVar metricsVar
        pure $ case m.state of
          Processing info _ -> info.inFlight
          _ -> 1

      addAttribute traceSpan attrShibuyaInflightCount currentInflight
      addAttribute traceSpan attrShibuyaInflightMax maxConc

      -- Record handler start event
      addEvent traceSpan (mkEvent eventHandlerStarted [])

      -- Call handler and finalize
      result <-
        catchAny
          ( do
              decision <- handler ingested
              ingested.ack.finalize decision
              pure (Right decision)
          )
          ( \ex -> do
              recordException traceSpan ex
              addEvent traceSpan (mkEvent eventHandlerException [])
              pure $ Left $ HandlerException $ Text.pack $ show ex
          )

      -- Record completion event and set status
      case result of
        Right decision -> do
          let decisionText = showAckDecision decision
          addEvent traceSpan $
            mkEvent
              eventHandlerCompleted
              [(attrShibuyaAckDecision, OTel.toAttribute decisionText)]
          addAttribute traceSpan attrShibuyaAckDecision decisionText

          -- Set span status based on decision
          case decision of
            AckOk -> setStatus traceSpan OTel.Ok
            AckRetry _ -> setStatus traceSpan OTel.Ok
            AckDeadLetter reason ->
              setStatus traceSpan $ OTel.Error $ showDeadLetterReason reason
            AckHalt reason ->
              setStatus traceSpan $ OTel.Error $ showHaltReason reason
        Left err -> do
          addEvent traceSpan $
            mkEvent
              eventAckDecision
              [(attrShibuyaAckDecision, OTel.toAttribute ("error" :: Text))]
          setStatus traceSpan $ OTel.Error $ handlerErrorToText err

      -- Decrement in-flight and update stats
      now' <- liftIO getCurrentTime
      liftIO $ atomically $ modifyTVar' metricsVar $ decrementAndUpdate result now'

      -- Handle halt (set flag, don't throw - let stream drain)
      case result of
        Right (AckHalt reason) -> liftIO $ atomicWriteIORef haltRef (Just reason)
        _ -> pure ()
  where
    showAckDecision :: AckDecision -> Text
    showAckDecision AckOk = "ack_ok"
    showAckDecision (AckRetry _) = "ack_retry"
    showAckDecision (AckDeadLetter _) = "ack_dead_letter"
    showAckDecision (AckHalt _) = "ack_halt"

    showDeadLetterReason :: DeadLetterReason -> Text
    showDeadLetterReason (PoisonPill t) = "poison_pill: " <> t
    showDeadLetterReason (InvalidPayload t) = "invalid_payload: " <> t
    showDeadLetterReason MaxRetriesExceeded = "max_retries_exceeded"

    showHaltReason :: HaltReason -> Text
    showHaltReason (HaltOrderedStream t) = "halt_ordered_stream: " <> t
    showHaltReason (HaltFatal t) = "halt_fatal: " <> t

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
