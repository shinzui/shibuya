-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Supervised runner - runs processors under NQE supervision with metrics.
-- This is the production runner with introspection and control.
--
-- Architecture:
-- - Each processor runs as a child under the Master's supervisor
-- - Metrics are tracked in a TVar and registered with the Master
-- - Backpressure is provided via bounded inbox between stream and processor
module Shibuya.Internal.Runner.Supervised
  ( -- * Running with Supervision
    runSupervised,
    runSupervisedBatch,

    -- * Standalone (without Master)
    runWithMetrics,
    runWithMetricsBatch,

    -- * Processor Handle
    SupervisedProcessor (..),

    -- * Introspection
    getMetrics,
    getProcessorState,
    isDone,
  )
where

import Control.Concurrent.NQE.Process (Inbox, mailboxEmptySTM, newBoundedInbox, receiveSTM)
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
import Control.Monad (when)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO, (:>))
import Effectful.Dispatch.Static (unsafeEff_)
import OpenTelemetry.Attributes (Attribute, toAttribute)
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Adapter (Adapter (..))
import Shibuya.Batch (BatchConfig, BatchHandler)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.Error (HandlerError (..), handlerErrorToText)
import Shibuya.Core.Ingested (Ingested (..), toMessage)
import Shibuya.Core.Metrics
  ( AckDecisionMetric (..),
    MetricsHandle (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    beginProcessing,
    finishFinalizationFailure,
    finishProcessing,
    newMetricsHandle,
    sampleMetrics,
  )
import Shibuya.Core.Metrics qualified as Metrics
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.BatchProcessor (processBatchesUntilDrained)
import Shibuya.Internal.Runner.Batcher (runBatcher)
import Shibuya.Internal.Runner.Finalize (finalizeWithRetry)
import Shibuya.Internal.Runner.Halt (ProcessorHalt (..))
import Shibuya.Internal.Runner.Ingester (runIngesterWithMetrics)
import Shibuya.Internal.Runner.KeyedScheduler (runKeyedScheduler)
import Shibuya.Internal.Runner.Master (Master (..), MasterState (..), registerProcessor, unregisterProcessor)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Prelude
import Shibuya.Telemetry.Effect
  ( Tracing,
    addAttribute,
    addAttributes,
    addEvent,
    recordException,
    setStatus,
    withExtractedContext,
    withSpan',
  )
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic
  ( attrMessagingDestinationName,
    attrMessagingMessageId,
    attrMessagingOperation,
    attrMessagingSystem,
    attrShibuyaAckDecision,
    attrShibuyaInflightCount,
    attrShibuyaInflightMax,
    attrShibuyaPartition,
    consumerSpanArgs,
    eventAckDecision,
    eventHandlerCompleted,
    eventHandlerStarted,
    mkEvent,
    processSpanName,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Stream.Prelude qualified as StreamP
import UnliftIO (Async, catch, catchAny, displayException, finally, throwIO)
import UnliftIO qualified as UIO

-- | Handle for a supervised processor.
-- Provides introspection into the running processor.
data SupervisedProcessor = SupervisedProcessor
  { -- | Live metrics for this processor
    metrics :: !MetricsHandle,
    -- | The processor's ID
    processorId :: !ProcessorId,
    -- | Whether processing is complete
    done :: !(TVar Bool),
    -- | The async handle if running under supervision
    child :: !(Maybe (Async ()))
  }

-- | Get current metrics for the processor.
getMetrics :: (IOE :> es) => SupervisedProcessor -> Eff es ProcessorMetrics
getMetrics sp = liftIO $ sampleMetrics sp.metrics

-- | Get current state of the processor.
getProcessorState :: (IOE :> es) => SupervisedProcessor -> Eff es ProcessorState
getProcessorState sp = liftIO $ (.state) <$> sampleMetrics sp.metrics

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
  -- | OrderingPolicy policy
  OrderingPolicy ->
  -- | Concurrency mode
  Concurrency ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Message handler
  Handler es msg ->
  Eff es SupervisedProcessor
runSupervised master inboxSize procId ordering concurrency adapter handler = do
  now <- liftIO getCurrentTime

  -- Initialize state
  metricsHandle <- liftIO $ newMetricsHandle now
  doneVar <- liftIO $ newTVarIO False

  -- Register with Master
  registerProcessor master procId metricsHandle

  -- Add as supervised child using NQE's Supervisor
  -- ConcUnlift Persistent allows the runInIO function to be used in the async child
  supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    addChild master.state.supervisor $
      runInIO
        ( -- Catch ProcessorHalt to prevent propagation via link
          -- (Halt is intentional, not a failure - other processors should continue)
          ( runIngesterAndProcessor metricsHandle procId inboxSize ordering concurrency adapter handler
              `catch` \(ProcessorHalt _) -> pure () -- Convert halt to graceful exit
          )
            `finally` unregisterProcessor master procId
        )
        `finally` atomically (writeTVar doneVar True)

  -- Link so exceptions propagate to the parent for strategies that request it.
  when master.state.propagateFailures $
    unsafeEff_ $
      UIO.link supervisedChild

  pure
    SupervisedProcessor
      { metrics = metricsHandle,
        processorId = procId,
        done = doneVar,
        child = Just supervisedChild
      }

-- | Run a processor with metrics but without Master supervision.
-- Useful for testing or simple single-processor setups.
-- This blocks until the stream is exhausted and all messages are processed
-- using serial processing with the same concurrent ingester/drainer shape as
-- the supervised runner.
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
  metricsHandle <- liftIO $ newMetricsHandle now
  doneVar <- liftIO $ newTVarIO False

  runIngesterAndProcessor metricsHandle procId inboxSize Unordered Serial adapter handler
    `finally` liftIO (atomically (writeTVar doneVar True))

  pure
    SupervisedProcessor
      { metrics = metricsHandle,
        processorId = procId,
        done = doneVar,
        child = Nothing
      }

-- | Run ingester and processor with a bounded inbox.
-- Ingester reads from adapter stream, processor calls handler.
-- When stream exhausts, processor drains remaining messages and exits.
runIngesterAndProcessor ::
  (IOE :> es, Tracing :> es) =>
  MetricsHandle ->
  ProcessorId ->
  Natural ->
  OrderingPolicy ->
  Concurrency ->
  Adapter es msg ->
  Handler es msg ->
  Eff es ()
runIngesterAndProcessor metricsHandle procId inboxSize ordering concurrency adapter handler = do
  -- Create bounded inbox (this is where inboxSize is used for backpressure)
  inbox <- liftIO $ newBoundedInbox inboxSize

  -- Signal when ingester completes (stream exhausted)
  streamDoneVar <- liftIO $ newTVarIO False

  -- Run ingester async, processor in main thread
  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    -- Ingester: run until stream exhausts, then signal done
    -- Use finally to ensure streamDoneVar is always set, even if ingester fails
    let ingesterWithSignal =
          runInIO (runIngesterWithMetrics metricsHandle adapter.source inbox)
            `finally` atomically (writeTVar streamDoneVar True)

    UIO.withAsync ingesterWithSignal $ \ingesterAsync -> do
      -- Processor: process messages, exit when stream done and inbox empty
      runInIO $ processUntilDrained metricsHandle procId ordering concurrency handler inbox streamDoneVar
      UIO.waitCatch ingesterAsync >>= \case
        Left ingesterErr -> do
          now <- getCurrentTime
          atomically $
            modifyTVar' metricsHandle.cold $ \m ->
              m {Metrics.state = Failed (Text.pack (displayException ingesterErr)) now}
          UIO.throwIO ingesterErr
        Right () -> pure ()

-- | Run a batching processor under the Master's supervision with metrics.
--
-- Identical in shape to 'runSupervised' but the inner loop accumulates messages
-- into batches (via the 'BatchConfig') and runs a 'BatchHandler' over each batch,
-- finalizing every message exactly once. On a batch-handler halt the child exits
-- gracefully (the processor halt is caught here), matching 'runSupervised'.
runSupervisedBatch ::
  (IOE :> es, Tracing :> es) =>
  Master ->
  -- | Inbox size (for backpressure)
  Natural ->
  -- | Processor identifier
  ProcessorId ->
  -- | Concurrency mode (bounds how many BATCHES run at once)
  Concurrency ->
  -- | Batch configuration
  BatchConfig es msg ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Batch handler
  BatchHandler es msg ->
  Eff es SupervisedProcessor
runSupervisedBatch master inboxSize procId concurrency batchConfig adapter batchHandler = do
  now <- liftIO getCurrentTime

  metricsHandle <- liftIO $ newMetricsHandle now
  doneVar <- liftIO $ newTVarIO False

  registerProcessor master procId metricsHandle

  supervisedChild <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    addChild master.state.supervisor $
      runInIO
        ( ( runIngesterAndProcessorBatch
              metricsHandle
              procId
              inboxSize
              concurrency
              batchConfig
              adapter
              batchHandler
              `catch` \(ProcessorHalt _) -> pure ()
          )
            `finally` unregisterProcessor master procId
        )
        `finally` atomically (writeTVar doneVar True)

  when master.state.propagateFailures $
    unsafeEff_ $
      UIO.link supervisedChild

  pure
    SupervisedProcessor
      { metrics = metricsHandle,
        processorId = procId,
        done = doneVar,
        child = Just supervisedChild
      }

-- | Run a batching processor with metrics but without Master supervision.
-- Blocks until the adapter stream is exhausted and every accumulated batch has
-- been processed (including the end-of-input flush). Useful for tests.
runWithMetricsBatch ::
  (IOE :> es, Tracing :> es) =>
  Natural ->
  ProcessorId ->
  Concurrency ->
  BatchConfig es msg ->
  Adapter es msg ->
  BatchHandler es msg ->
  Eff es SupervisedProcessor
runWithMetricsBatch inboxSize procId concurrency batchConfig adapter batchHandler = do
  now <- liftIO getCurrentTime

  metricsHandle <- liftIO $ newMetricsHandle now
  doneVar <- liftIO $ newTVarIO False

  runIngesterAndProcessorBatch
    metricsHandle
    procId
    inboxSize
    concurrency
    batchConfig
    adapter
    batchHandler
    `finally` liftIO (atomically (writeTVar doneVar True))

  pure
    SupervisedProcessor
      { metrics = metricsHandle,
        processorId = procId,
        done = doneVar,
        child = Nothing
      }

-- | Run ingester and batch processor with a bounded inbox.
-- The ingester reads from the adapter stream into the inbox exactly as in the
-- single-message path; 'inboxToStream' turns the inbox into a halt-aware,
-- stream-done-aware Stream; 'runBatcher' groups that into ready batches; and
-- 'processBatchesUntilDrained' runs the batch handler and finalizes each message
-- exactly once. When the adapter stream ends (including on graceful shutdown,
-- when 'Adapter.shutdown' ends 'source'), the ingester completes, sets
-- streamDoneVar, 'inboxToStream' terminates once the inbox is empty, the batcher
-- reaches end-of-input and flushes all pending partial batches with TriggerFlush,
-- and only then does 'processBatchesUntilDrained' return. The spawn sites
-- ('runSupervised', 'runSupervisedBatch', and 'runWithMetricsBatch') own
-- marking the processor done via 'finally'.
--
-- 'processBatchesUntilDrained' (EP-18) only /sets/ the halt reference on a
-- batch-handler @AckHalt@ or exhausted finalization; it does not throw. So we
-- read the halt reference after it returns and throw a processor halt here,
-- mirroring the single-message
-- 'processUntilDrained'.
runIngesterAndProcessorBatch ::
  (IOE :> es, Tracing :> es) =>
  MetricsHandle ->
  ProcessorId ->
  Natural ->
  Concurrency ->
  BatchConfig es msg ->
  Adapter es msg ->
  BatchHandler es msg ->
  Eff es ()
runIngesterAndProcessorBatch metricsHandle procId inboxSize concurrency batchConfig adapter batchHandler = do
  inbox <- liftIO $ newBoundedInbox inboxSize
  streamDoneVar <- liftIO $ newTVarIO False
  haltRef <- liftIO $ newIORef Nothing

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let ingesterWithSignal =
          runInIO (runIngesterWithMetrics metricsHandle adapter.source inbox)
            `finally` atomically (writeTVar streamDoneVar True)

    UIO.withAsync ingesterWithSignal $ \ingesterAsync -> do
      let inboxStream = inboxToStream inbox streamDoneVar haltRef
          readyBatchStream = runBatcher inboxSize batchConfig inboxStream
          batchProcessor =
            runInIO $ do
              processBatchesUntilDrained
                metricsHandle
                procId
                concurrency
                batchHandler
                readyBatchStream
                haltRef
              maybeHalt <- liftIO (readIORef haltRef)
              maybe (pure ()) (throwIO . ProcessorHalt) maybeHalt
      batchProcessor `catchAny` \processorErr -> do
        now <- getCurrentTime
        atomically $
          modifyTVar' metricsHandle.cold $ \m ->
            m {Metrics.state = Failed (Text.pack (displayException processorErr)) now}
        UIO.throwIO processorErr
      UIO.waitCatch ingesterAsync >>= \case
        Left ingesterErr -> do
          now <- getCurrentTime
          atomically $
            modifyTVar' metricsHandle.cold $ \m ->
              m {Metrics.state = Failed (Text.pack (displayException ingesterErr)) now}
          UIO.throwIO ingesterErr
        Right () -> pure ()

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
  MetricsHandle ->
  ProcessorId ->
  OrderingPolicy ->
  Concurrency ->
  Handler es msg ->
  Inbox (Ingested es msg) ->
  TVar Bool ->
  Eff es ()
processUntilDrained metricsHandle procId ordering concurrency handler inbox streamDoneVar = do
  haltRef <- liftIO $ newIORef Nothing

  let maxConc = case concurrency of
        Serial -> 1
        Ahead n -> n
        Async n -> n
      ProcessorId pidText = procId
      spanName = processSpanName pidText
      constantFrameworkAttrs =
        HashMap.fromList
          [ (attrMessagingSystem, toAttribute ("shibuya" :: Text)),
            (attrMessagingDestinationName, toAttribute pidText),
            (attrMessagingOperation, toAttribute ("process" :: Text))
          ]

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let inboxStream = inboxToStream inbox streamDoneVar haltRef
        processAction = runInIO . processOne metricsHandle spanName constantFrameworkAttrs maxConc haltRef handler
        partitioned n =
          runKeyedScheduler
            (max 1 n)
            (max 2 (2 * max 1 n))
            (\ingested -> ingested.envelope.partition)
            processAction
            inboxStream

    case (ordering, concurrency) of
      (_, Serial) ->
        Stream.fold Fold.drain $
          Stream.mapM processAction inboxStream
      (PartitionedInOrder, Ahead n) ->
        partitioned n
      (PartitionedInOrder, Async n) ->
        partitioned n
      -- 'maxThreads n' is the hard concurrency bound (at most n handlers run at
      -- once); do not remove it. The output buffer is set to '2 * n', not 'n':
      -- a buffer equal to the thread count throttles streamly's worker dispatch
      -- (a worker is only forked when both the thread AND buffer checks pass),
      -- causing dispatch churn that allocated up to +90% on the Async
      -- concurrency-levels benchmarks. Enlarging the buffer to 2n relieves the
      -- churn while keeping the n-thread bound, and matches the pending-item
      -- limit the partitioned path already uses (see 'partitioned' above). See
      -- docs/plans/30-investigate-and-reduce-the-async-ahead-concurrency-allocation-regression.md.
      (_, Ahead n) ->
        Stream.fold Fold.drain $
          StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer (2 * n) . StreamP.ordered True) processAction inboxStream
      (_, Async n) ->
        Stream.fold Fold.drain $
          StreamP.parMapM (StreamP.maxThreads n . StreamP.maxBuffer (2 * n)) processAction inboxStream

    -- After draining, check if we halted
    maybeHalt <- readIORef haltRef
    case maybeHalt of
      Just reason -> throwIO $ ProcessorHalt reason
      Nothing -> pure ()

handlerStartedEvent :: OTel.NewEvent
handlerStartedEvent = mkEvent eventHandlerStarted []
{-# NOINLINE handlerStartedEvent #-}

-- | Process a single message with metrics tracking and tracing.
-- Thread-safe for concurrent execution.
processOne ::
  (IOE :> es, Tracing :> es) =>
  MetricsHandle ->
  Text ->
  HashMap.HashMap Text Attribute ->
  Int ->
  IORef (Maybe HaltReason) ->
  Handler es msg ->
  Ingested es msg ->
  Eff es ()
processOne metricsHandle spanName constantFrameworkAttrs maxConc haltRef handler ingested = do
  -- Extract parent context from message headers for distributed tracing
  let parentCtx = ingested.envelope.traceContext >>= extractTraceContext

  withExtractedContext parentCtx $
    withSpan' spanName consumerSpanArgs $ \traceSpan -> do
      -- Build the messaging.* attribute set: framework defaults first,
      -- then the adapter's HashMap layered on top so adapter keys with
      -- the same name override the framework's default. The explicit
      -- 'HashMap.union' here is left-biased (left wins), which keeps
      -- the precedence rule local and obvious instead of relying on
      -- the order of repeated 'addAttribute' / 'addAttributes' calls
      -- against the underlying mutable Span.
      let MessageId msgIdText = ingested.envelope.messageId
          frameworkAttrs =
            HashMap.insert attrMessagingMessageId (toAttribute msgIdText) $
              case ingested.envelope.partition of
                Just p -> HashMap.insert attrShibuyaPartition (toAttribute p) constantFrameworkAttrs
                Nothing -> constantFrameworkAttrs
          mergedAttrs = HashMap.union ingested.envelope.attributes frameworkAttrs
      addAttributes traceSpan mergedAttrs

      -- Increment in-flight and add inflight attributes.
      currentInflight <- liftIO $ beginProcessing metricsHandle maxConc

      addAttribute traceSpan attrShibuyaInflightCount currentInflight
      addAttribute traceSpan attrShibuyaInflightMax maxConc

      -- Record handler start event
      addEvent traceSpan handlerStartedEvent

      -- Call handler and finalizer separately. A handler exception is
      -- substituted with immediate retry so the adapter always observes a
      -- finalization decision for an ingested message.
      --
      -- This is a *separate* per-message 'catchAny' from the one inside
      -- 'finalizeWithRetry' below. 0.7.1.0 used a single combined catch around
      -- handler+finalize, which skipped finalization when the handler threw;
      -- splitting them is what makes "always finalize" hold. The extra
      -- per-message exception frame costs ~126 bytes/message (measured, EP-31
      -- S3: docs/plans/31-…-shared-per-message-…-allocation-regression.md) and is
      -- accepted as the price of the always-finalize guarantee — do not merge the
      -- two catches back together to reclaim it.
      handlerResult <-
        catchAny
          (Right <$> handler (toMessage ingested))
          ( \ex -> do
              recordException traceSpan ex
              pure (Left ex)
          )
      let (decision, result) = case handlerResult of
            Right d -> (d, Right d)
            Left ex ->
              ( AckRetry (RetryDelay 0),
                Left $ HandlerException $ Text.pack $ show ex
              )

      when (isLeft handlerResult) $
        addEvent traceSpan $
          mkEvent
            eventAckDecision
            [(attrShibuyaAckDecision, OTel.toAttribute ("ack_retry" :: Text))]

      finalizeResult <- finalizeWithRetry traceSpan ingested decision

      -- Record completion event and set status
      case finalizeResult of
        Left _ -> do
          addEvent traceSpan $
            mkEvent
              eventAckDecision
              [(attrShibuyaAckDecision, OTel.toAttribute ("finalization_failed" :: Text))]
          setStatus traceSpan $ OTel.Error $ finalizationFailureText msgIdText
        Right () -> case result of
          Right decision' -> do
            let decisionText = showAckDecision decision'
            addEvent traceSpan $
              mkEvent
                eventHandlerCompleted
                [(attrShibuyaAckDecision, OTel.toAttribute decisionText)]
            addAttribute traceSpan attrShibuyaAckDecision decisionText

            -- Set span status based on decision
            case decision' of
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

      -- Decrement in-flight and update stats.
      liftIO $
        case finalizeResult of
          Left _ -> finishFinalizationFailure metricsHandle (finalizationFailureText msgIdText)
          Right () -> finishProcessing metricsHandle (metricForResult result)

      -- Handle halt (set flag, don't throw - let stream drain)
      case finalizeResult of
        Left _ ->
          liftIO $ atomicWriteIORef haltRef (Just (HaltFatal (finalizationFailureText msgIdText)))
        Right () -> case result of
          Right (AckHalt reason) -> liftIO $ atomicWriteIORef haltRef (Just reason)
          _ -> pure ()
  where
    isLeft :: Either a b -> Bool
    isLeft (Left _) = True
    isLeft (Right _) = False

    finalizationFailureText :: Text -> Text
    finalizationFailureText msgIdText =
      "finalization failed for message id: " <> msgIdText

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

metricForResult :: Either HandlerError AckDecision -> Either Text AckDecisionMetric
metricForResult (Left err) = Left (handlerErrorToText err)
metricForResult (Right AckOk) = Right CountProcessed
metricForResult (Right (AckRetry _)) = Right CountProcessed
metricForResult (Right (AckDeadLetter _)) = Right CountFailed
metricForResult (Right (AckHalt reason)) = Right (CountHalt (haltReasonText reason))
  where
    haltReasonText (HaltOrderedStream t) = t
    haltReasonText (HaltFatal t) = t
