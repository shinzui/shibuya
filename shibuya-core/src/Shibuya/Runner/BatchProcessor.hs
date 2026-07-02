-- | Batch execution stage: run a batch handler over an emitted batch, resolve
-- one acknowledgement decision per retained message, and finalize resiliently.
--
-- This is the reliability heart of batch processing. For each ready batch it:
--
--   1. Opens an OpenTelemetry span scoped to the whole batch.
--   2. Runs the user's 'BatchHandler' under exception isolation.
--   3. On success, uses the returned 'BatchAck'; on exception, substitutes the
--      framework default @ackAll (AckRetry (RetryDelay 0))@ (redeliver the whole
--      batch, no data loss).
--   4. Resolves EVERY message in its OWN retained 'NonEmpty' list to one
--      decision, looking each decision up by 'MessageId' with a fallback.
--   5. Calls each message's idempotent finalizer with bounded retry. If retry
--      is exhausted, records the message id and fails the processor loudly.
--   6. On 'AckHalt', sets a shared halt flag (does not throw); the caller drains
--      then throws 'ProcessorHalt'.
--   7. Records batch metrics.
--
-- The decision loop iterates the framework's retained list, never the handler's
-- output, so handler bugs cannot skip or misassign retained messages.
module Shibuya.Runner.BatchProcessor
  ( -- * Batch execution
    processOneBatch,
    processBatchesUntilDrained,

    -- * Standalone driver (for tests / finite batch lists)
    runBatchesWithMetrics,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    writeTVar,
  )
import Data.Foldable (for_, traverse_)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Unique (Unique, newUnique)
import Effectful (Eff, IOE, liftIO, withEffToIO, (:>))
import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))
import OpenTelemetry.Attributes (toAttribute)
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Batch
  ( BatchAck (..),
    BatchHandler,
    BatchInfo (..),
    BatchKey (..),
    BatchTrigger (..),
    ackAll,
  )
import Shibuya.Core.Ack
  ( AckDecision (..),
    HaltReason (..),
    RetryDelay (..),
  )
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Prelude
import Shibuya.Runner.Finalize (finalizeWithRetry)
import Shibuya.Runner.Halt (ProcessorHalt (..))
import Shibuya.Runner.Metrics
  ( BatchStats,
    InFlightInfo (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats,
    addBatchedMessages,
    emptyProcessorMetrics,
    incBatchesEmitted,
    incFailed,
    incFlushTriggered,
    incPartialFailures,
    incProcessed,
    incSizeTriggered,
    incTimeoutTriggered,
  )
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
    attrMessagingOperation,
    attrMessagingSystem,
    attrShibuyaBatchKey,
    attrShibuyaBatchSize,
    attrShibuyaBatchTrigger,
    attrShibuyaInflightCount,
    attrShibuyaInflightMax,
    consumerSpanArgs,
    eventBatchCompleted,
    eventBatchStarted,
    mkEvent,
    processSpanName,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO (SomeException, catchAny, finally, throwIO)
import UnliftIO.Async (Async, async, cancel, withAsync)

-- | Execute one emitted batch and finalize every retained message resiliently.
--
-- @maxConc@ is the batch-concurrency limit (reported on the span). @haltRef@ is
-- the shared halt flag: on 'AckHalt' this sets it via 'atomicWriteIORef' and
-- returns normally, letting the stream drain.
processOneBatch ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Int ->
  IORef (Maybe HaltReason) ->
  BatchHandler es msg ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  Eff es ()
processOneBatch metricsVar procId maxConc haltRef handler (info, batch) = do
  -- Use the first message's trace context as the batch span's parent. A batch
  -- may span several traces; picking the first is a pragmatic single parent
  -- (full fan-in links are a later refinement).
  let firstMsg = NE.head batch
      parentCtx = firstMsg.envelope.traceContext >>= extractTraceContext
      ProcessorId pidText = procId

  withExtractedContext parentCtx $
    withSpan' (processSpanName pidText) consumerSpanArgs $ \traceSpan -> do
      -- Framework messaging.* attributes plus batch-scoped attributes.
      let BatchKey keyText = info.batchKey
          frameworkAttrs =
            HashMap.fromList
              [ (attrMessagingSystem, toAttribute ("shibuya" :: Text)),
                (attrMessagingDestinationName, toAttribute pidText),
                (attrMessagingOperation, toAttribute ("process" :: Text)),
                (attrShibuyaBatchKey, toAttribute keyText),
                (attrShibuyaBatchSize, toAttribute info.size),
                (attrShibuyaBatchTrigger, toAttribute (triggerText info.trigger))
              ]
      addAttributes traceSpan frameworkAttrs

      -- Increment in-flight (a batch counts as one in-flight unit) and report it.
      now <- liftIO getCurrentTime
      currentInflight <- liftIO $ atomically $ do
        modifyTVar' metricsVar $ \m ->
          let current = case m.state of
                Processing i _ -> i.inFlight
                _ -> 0
           in m & #state .~ Processing (InFlightInfo (current + 1) maxConc) now
        m <- readTVar metricsVar
        pure $ case m.state of
          Processing i _ -> i.inFlight
          _ -> 1
      addAttribute traceSpan attrShibuyaInflightCount currentInflight
      addAttribute traceSpan attrShibuyaInflightMax maxConc

      addEvent traceSpan (mkEvent eventBatchStarted [])

      alreadyHalted <- liftIO $ readIORef haltRef

      -- Run the handler under exception isolation. On any exception, record it
      -- on the span and substitute the whole-batch retry default.
      (handlerResult, skippedAfterHalt) <-
        case alreadyHalted of
          Just _ -> pure (Left (), True)
          Nothing -> do
            result <-
              catchAny
                (Right <$> handler info batch)
                ( \ex -> do
                    recordException traceSpan ex
                    pure (Left ())
                )
            pure (result, False)
      let (resolvedAck, handlerThrew) = case handlerResult of
            Right a -> (a, False)
            Left () -> (ackAll (AckRetry (RetryDelay 0)), True)

      -- RELIABLE FINALIZATION: iterate OUR OWN retained list, never the
      -- handler's output. For each retained message, choose its decision once
      -- via findWithDefault, then call the idempotent adapter finalizer with
      -- bounded retry. Do not let one adapter failure prevent attempts for the
      -- rest of the batch.
      results <-
        mapM
          ( \ingested -> do
              let d =
                    Map.findWithDefault
                      resolvedAck.fallback
                      ingested.envelope.messageId
                      resolvedAck.decisions
              finalResult <- finalizeWithRetry traceSpan ingested d
              pure (ingested.envelope.messageId, d, finalResult)
          )
          (NE.toList batch)
      let decisions = [d | (_, d, _) <- results]
          finalizeFailures = [(mid, ex) | (mid, _, Left ex) <- results]

      -- Compute halt and partial-failure signals from the resolved decisions.
      let finalizationHalt =
            case finalizeFailures of
              [] -> Nothing
              failed ->
                Just $
                  HaltFatal $
                    "batch finalization failed for message ids: "
                      <> Text.intercalate ", " [tshow mid | (mid, _) <- failed]
          firstHalt = finalizationHalt <|> listToMaybe [r | AckHalt r <- decisions]
          overrideFailures =
            [ ()
            | ingested <- NE.toList batch,
              Just d <- [Map.lookup ingested.envelope.messageId resolvedAck.decisions],
              isFailing d
            ]
          partialInc = not handlerThrew && not (null overrideFailures)

      -- Span status: error on halt or exception, otherwise Ok.
      addEvent traceSpan (mkEvent eventBatchCompleted [])
      case firstHalt of
        Just reason -> setStatus traceSpan (OTel.Error (haltReasonText reason))
        Nothing ->
          if skippedAfterHalt
            then setStatus traceSpan (OTel.Error "batch skipped after halt")
            else
              if handlerThrew
                then setStatus traceSpan (OTel.Error "batch handler exception")
                else setStatus traceSpan OTel.Ok

      traverse_ (recordException traceSpan . snd) finalizeFailures

      -- Record metrics: decrement in-flight, fold per-message stats, advance
      -- batch counters, set Failed state on halt or exhausted finalization retry.
      now' <- liftIO getCurrentTime
      liftIO $
        atomically $
          modifyTVar' metricsVar $
            recordBatchOutcome info handlerThrew partialInc decisions firstHalt now'

      -- Halt: set the shared flag; do NOT throw (let the stream drain).
      for_ firstHalt $ \reason ->
        liftIO $ atomicWriteIORef haltRef (Just reason)
  where
    isFailing :: AckDecision -> Bool
    isFailing (AckDeadLetter _) = True
    isFailing (AckRetry _) = True
    isFailing _ = False

-- | Pure metrics update applied after a batch is fully finalized.
recordBatchOutcome ::
  BatchInfo ->
  -- | whether the handler threw (exception-substituted whole batch)
  Bool ->
  -- | whether to count a partial failure
  Bool ->
  -- | resolved decisions, in retained order
  [AckDecision] ->
  -- | first halt reason, if any
  Maybe HaltReason ->
  UTCTime ->
  ProcessorMetrics ->
  ProcessorMetrics
recordBatchOutcome info handlerThrew partialInc decisions firstHalt now m =
  m {state = finalState, stats = newStats, batch = newBatch}
  where
    decremented = case m.state of
      Processing i _ ->
        if i.inFlight <= 1
          then Idle
          else Processing (i {inFlight = i.inFlight - 1}) now
      other -> other
    -- Halt is terminal -> Failed; exception is recoverable -> keep normal state.
    finalState = case firstHalt of
      Just reason -> Failed (haltReasonText reason) now
      Nothing -> decremented
    newStats = foldl' (\s d -> perMsgStat handlerThrew d s) m.stats decisions
    newBatch =
      incTrigger info.trigger
        . (if partialInc then incPartialFailures else id)
        . addBatchedMessages info.size
        . incBatchesEmitted
        $ m.batch

-- | Map one message's outcome to a stats update. If the handler threw, every
-- message counts failed regardless of the substituted retry decision.
perMsgStat :: Bool -> AckDecision -> StreamStats -> StreamStats
perMsgStat True _ = incFailed
perMsgStat False AckOk = incProcessed
perMsgStat False (AckRetry _) = incProcessed
perMsgStat False (AckDeadLetter _) = incFailed
perMsgStat False (AckHalt _) = id

incTrigger :: BatchTrigger -> BatchStats -> BatchStats
incTrigger TriggerSize = incSizeTriggered
incTrigger TriggerTimeout = incTimeoutTriggered
incTrigger TriggerFlush = incFlushTriggered

triggerText :: BatchTrigger -> Text
triggerText TriggerSize = "size"
triggerText TriggerTimeout = "timeout"
triggerText TriggerFlush = "flush"

haltReasonText :: HaltReason -> Text
haltReasonText (HaltOrderedStream t) = t
haltReasonText (HaltFatal t) = t

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- | Fold the ready-batch stream, running each batch under the batch-concurrency
-- policy. Batches with the same 'BatchKey' are always serialized in emission
-- order; different keys may run concurrently up to the configured bound. This
-- does NOT throw on halt; after draining, the caller inspects @haltRef@ and
-- throws 'ProcessorHalt' (see 'runBatchesWithMetrics').
processBatchesUntilDrained ::
  (IOE :> es, Tracing :> es) =>
  TVar ProcessorMetrics ->
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IORef (Maybe HaltReason) ->
  Eff es ()
processBatchesUntilDrained metricsVar procId concurrency handler batchStream haltRef = do
  let maxConc = case concurrency of
        Serial -> 1
        Ahead n -> n
        Async n -> n

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let batchAction = runInIO . processOneBatch metricsVar procId maxConc haltRef handler
        pendingLimit = max 2 (2 * max 1 maxConc)
    case concurrency of
      Serial ->
        Stream.fold Fold.drain $
          Stream.mapM batchAction batchStream
      Ahead n ->
        runKeyedBatchScheduler n pendingLimit batchAction batchStream
      Async n ->
        runKeyedBatchScheduler n pendingLimit batchAction batchStream

-- | Per-key FIFO scheduler state, guarded by a single 'TVar'.
data KeyedSchedulerState es msg = KeyedSchedulerState
  { inputDone :: !Bool,
    activeKeys :: !(Set.Set BatchKey),
    running :: !Int,
    pending :: !(Seq (BatchInfo, NonEmpty (Ingested es msg))),
    firstFailure :: !(Maybe SomeException)
  }

data SchedulerStep es msg
  = StartBatch !(BatchInfo, NonEmpty (Ingested es msg))
  | SchedulerDone !(Maybe SomeException)

emptyKeyedSchedulerState :: KeyedSchedulerState es msg
emptyKeyedSchedulerState =
  KeyedSchedulerState
    { inputDone = False,
      activeKeys = Set.empty,
      running = 0,
      pending = Seq.empty,
      firstFailure = Nothing
    }

runKeyedBatchScheduler ::
  Int ->
  Int ->
  ((BatchInfo, NonEmpty (Ingested es msg)) -> IO ()) ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IO ()
runKeyedBatchScheduler requestedConcurrency pendingLimit batchAction batchStream = do
  scheduler <- newTVarIO emptyKeyedSchedulerState
  workers <- newTVarIO (Map.empty :: Map.Map Unique (Async ()))
  let maxConcurrency = max 1 requestedConcurrency
      cancelWorkers = do
        liveWorkers <- readTVarIO workers
        traverse_ cancel (Map.elems liveWorkers)

      reader =
        ( do
            Stream.fold Fold.drain $
              Stream.mapM (enqueueBatch pendingLimit scheduler) batchStream
            atomically $ markInputDone scheduler Nothing
        )
          `catchAny` \ex ->
            atomically $ markInputDone scheduler (Just ex)

      loop = do
        step <- atomically $ nextSchedulerStep maxConcurrency scheduler
        case step of
          SchedulerDone Nothing -> pure ()
          SchedulerDone (Just ex) -> throwIO ex
          StartBatch batch -> do
            workerId <- newUnique
            startGate <- newEmptyMVar
            worker <- async $ do
              takeMVar startGate
              runWorker scheduler workers workerId batchAction batch
            atomically $ modifyTVar' workers (Map.insert workerId worker)
            putMVar startGate ()
            loop

  withAsync reader $ \_reader ->
    loop `finally` cancelWorkers

runWorker ::
  TVar (KeyedSchedulerState es msg) ->
  TVar (Map.Map Unique (Async ())) ->
  Unique ->
  ((BatchInfo, NonEmpty (Ingested es msg)) -> IO ()) ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  IO ()
runWorker scheduler workers workerId batchAction batch = do
  resultRef <- newIORef Nothing
  let runBatch =
        (batchAction batch >> pure Nothing)
          `catchAny` (pure . Just)
          >>= writeIORef resultRef
      cleanup = do
        result <- readIORef resultRef
        atomically $ finishBatch scheduler batch result
        atomically $ modifyTVar' workers (Map.delete workerId)
  runBatch `finally` cleanup

enqueueBatch ::
  Int ->
  TVar (KeyedSchedulerState es msg) ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  IO ()
enqueueBatch pendingLimit scheduler batch =
  atomically $ do
    s <- readTVar scheduler
    if Seq.length s.pending >= pendingLimit
      then retry
      else writeTVar scheduler s {pending = s.pending Seq.|> batch}

markInputDone ::
  TVar (KeyedSchedulerState es msg) ->
  Maybe SomeException ->
  STM ()
markInputDone scheduler failure =
  modifyTVar' scheduler $ \s ->
    s
      { inputDone = True,
        firstFailure = s.firstFailure <|> failure
      }

nextSchedulerStep ::
  Int ->
  TVar (KeyedSchedulerState es msg) ->
  STM (SchedulerStep es msg)
nextSchedulerStep maxConcurrency scheduler = do
  s <- readTVar scheduler
  case (s.running < maxConcurrency, popStartable s.activeKeys s.pending) of
    (True, Just (batch@(info, _), rest)) -> do
      writeTVar
        scheduler
        s
          { activeKeys = Set.insert info.batchKey s.activeKeys,
            running = s.running + 1,
            pending = rest
          }
      pure (StartBatch batch)
    _
      | s.inputDone && Seq.null s.pending && s.running == 0 ->
          pure (SchedulerDone s.firstFailure)
      | otherwise ->
          retry

finishBatch ::
  TVar (KeyedSchedulerState es msg) ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  Maybe SomeException ->
  STM ()
finishBatch scheduler (info, _) failure =
  modifyTVar' scheduler $ \s ->
    s
      { activeKeys = Set.delete info.batchKey s.activeKeys,
        running = s.running - 1,
        firstFailure = s.firstFailure <|> failure
      }

popStartable ::
  Set.Set BatchKey ->
  Seq (BatchInfo, NonEmpty (Ingested es msg)) ->
  Maybe ((BatchInfo, NonEmpty (Ingested es msg)), Seq (BatchInfo, NonEmpty (Ingested es msg)))
popStartable active = go Seq.empty
  where
    go skipped batches =
      case Seq.viewl batches of
        Seq.EmptyL ->
          Nothing
        batch@(info, _) Seq.:< rest
          | info.batchKey `Set.member` active ->
              go (skipped Seq.|> batch) rest
          | otherwise ->
              Just (batch, skipped <> rest)

-- | Self-contained driver for finite batch lists (tests / simple setups).
-- Mirrors 'Shibuya.Runner.Supervised.runWithMetrics': creates its own metrics
-- TVar and halt flag, runs execution to completion, and — after draining —
-- throws 'ProcessorHalt' if a batch requested a halt. Returns the final metrics.
runBatchesWithMetrics ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  [(BatchInfo, NonEmpty (Ingested es msg))] ->
  Eff es ProcessorMetrics
runBatchesWithMetrics procId concurrency handler batches = do
  now <- liftIO getCurrentTime
  metricsVar <- liftIO $ newTVarIO (emptyProcessorMetrics now)
  haltRef <- liftIO $ newIORef Nothing

  let batchStream = Stream.fromList batches
  processBatchesUntilDrained metricsVar procId concurrency handler batchStream haltRef

  maybeHalt <- liftIO $ readIORef haltRef
  case maybeHalt of
    Just reason -> throwIO (ProcessorHalt reason)
    Nothing -> liftIO $ readTVarIO metricsVar
