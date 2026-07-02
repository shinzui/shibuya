-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Batch execution stage: run a batch handler over an emitted batch, resolve
-- one acknowledgement decision per retained message, and finalize resiliently.
--
-- This is the reliability heart of batch processing. For each ready batch it:
--
--   1. Opens an OpenTelemetry span scoped to the whole batch.
--   2. Runs the user's 'BatchHandler' under exception isolation.
--   3. On success, uses the returned batch ack; on exception, substitutes the
--      framework default @ackAll (AckRetry (RetryDelay 0))@ (redeliver the whole
--      batch, no data loss).
--   4. Resolves EVERY message in its OWN retained 'NonEmpty' list to one
--      decision, looking each decision up by message id with a fallback.
--   5. Calls each message's idempotent finalizer with bounded retry. If retry
--      is exhausted, records the message id and fails the processor loudly.
--   6. On @AckHalt@, sets a shared halt flag (does not throw); the caller drains
--      then throws a processor halt.
--   7. Records batch metrics.
--
-- The decision loop iterates the framework's retained list, never the handler's
-- output, so handler bugs cannot skip or misassign retained messages.
module Shibuya.Internal.Runner.BatchProcessor
  ( -- * Batch execution
    processOneBatch,
    processBatchesUntilDrained,

    -- * Standalone driver (for tests / finite batch lists)
    runBatchesWithMetrics,
  )
where

import Control.Applicative ((<|>))
import Data.Foldable (for_, traverse_)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO, (:>))
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
import Shibuya.Core.Ingested (Ingested (..), toMessage)
import Shibuya.Core.Metrics
  ( AckDecisionMetric (..),
    BatchTriggerMetric (..),
    MetricsHandle (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    beginProcessing,
    newMetricsHandle,
    recordBatchOutcomeMetrics,
    sampleMetrics,
  )
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Internal.Runner.Finalize (finalizeWithRetry)
import Shibuya.Internal.Runner.Halt (ProcessorHalt (..))
import Shibuya.Internal.Runner.KeyedScheduler (runKeyedScheduler)
import Shibuya.Policy (Concurrency (..))
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
import UnliftIO (catchAny, throwIO)

-- | Execute one emitted batch and finalize every retained message resiliently.
--
-- @maxConc@ is the batch-concurrency limit (reported on the span). @haltRef@ is
-- the shared halt flag: on 'AckHalt' this sets it via 'atomicWriteIORef' and
-- returns normally, letting the stream drain.
processOneBatch ::
  (IOE :> es, Tracing :> es) =>
  MetricsHandle ->
  ProcessorId ->
  Int ->
  IORef (Maybe HaltReason) ->
  BatchHandler es msg ->
  (BatchInfo, NonEmpty (Ingested es msg)) ->
  Eff es ()
processOneBatch metricsHandle procId maxConc haltRef handler (info, batch) = do
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
      currentInflight <- liftIO $ beginProcessing metricsHandle maxConc
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
                (Right <$> handler info (toMessage <$> batch))
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

      -- Record metrics: decrement in-flight, add per-message counter deltas,
      -- advance batch counters, set Failed state on halt or exhausted
      -- finalization retry.
      liftIO $
        recordBatchOutcomeMetrics
          metricsHandle
          (triggerMetric info.trigger)
          info.size
          handlerThrew
          partialInc
          (decisionMetric <$> decisions)
          (haltReasonText <$> firstHalt)

      -- Halt: set the shared flag; do NOT throw (let the stream drain).
      for_ firstHalt $ \reason ->
        liftIO $ atomicWriteIORef haltRef (Just reason)
  where
    isFailing :: AckDecision -> Bool
    isFailing (AckDeadLetter _) = True
    isFailing (AckRetry _) = True
    isFailing _ = False

decisionMetric :: AckDecision -> AckDecisionMetric
decisionMetric AckOk = CountProcessed
decisionMetric (AckRetry _) = CountProcessed
decisionMetric (AckDeadLetter _) = CountFailed
decisionMetric (AckHalt reason) = CountHalt (haltReasonText reason)

triggerMetric :: BatchTrigger -> BatchTriggerMetric
triggerMetric TriggerSize = CountTriggerSize
triggerMetric TriggerTimeout = CountTriggerTimeout
triggerMetric TriggerFlush = CountTriggerFlush

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
-- policy. Batches with the same batch key are always serialized in emission
-- order; different keys may run concurrently up to the configured bound. This
-- does NOT throw on halt; after draining, the caller inspects @haltRef@ and
-- throws a processor halt (see 'runBatchesWithMetrics').
processBatchesUntilDrained ::
  (IOE :> es, Tracing :> es) =>
  MetricsHandle ->
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  Stream IO (BatchInfo, NonEmpty (Ingested es msg)) ->
  IORef (Maybe HaltReason) ->
  Eff es ()
processBatchesUntilDrained metricsHandle procId concurrency handler batchesStream haltRef = do
  let maxConc = case concurrency of
        Serial -> 1
        Ahead n -> n
        Async n -> n

  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
    let batchAction = runInIO . processOneBatch metricsHandle procId maxConc haltRef handler
        pendingLimit = max 2 (2 * max 1 maxConc)
    case concurrency of
      Serial ->
        Stream.fold Fold.drain $
          Stream.mapM batchAction batchesStream
      Ahead n ->
        runKeyedScheduler (max 1 n) pendingLimit (Just . fstBatchKey) batchAction batchesStream
      Async n ->
        runKeyedScheduler (max 1 n) pendingLimit (Just . fstBatchKey) batchAction batchesStream

fstBatchKey :: (BatchInfo, NonEmpty (Ingested es msg)) -> BatchKey
fstBatchKey (info, _) = info.batchKey

-- | Self-contained driver for finite batch lists (tests / simple setups).
-- Mirrors 'Shibuya.Internal.Runner.Supervised.runWithMetrics': creates its own metrics
-- TVar and halt flag, runs execution to completion, and — after draining —
-- throws a processor halt if a batch requested a halt. Returns the final metrics.
runBatchesWithMetrics ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  Concurrency ->
  BatchHandler es msg ->
  [(BatchInfo, NonEmpty (Ingested es msg))] ->
  Eff es ProcessorMetrics
runBatchesWithMetrics procId concurrency handler batches = do
  now <- liftIO getCurrentTime
  metricsHandle <- liftIO $ newMetricsHandle now
  haltRef <- liftIO $ newIORef Nothing

  let batchesStream = Stream.fromList batches
  processBatchesUntilDrained metricsHandle procId concurrency handler batchesStream haltRef

  maybeHalt <- liftIO $ readIORef haltRef
  case maybeHalt of
    Just reason -> throwIO (ProcessorHalt reason)
    Nothing -> liftIO $ sampleMetrics metricsHandle
