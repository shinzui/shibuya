-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Ingester - reads from adapter stream and sends to inbox.
-- Provides backpressure via bounded inbox.
module Shibuya.Internal.Runner.Ingester
  ( runIngester,
    runIngesterWithMetrics,
    runIngesterWithMetricsUnpaused,
  )
where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.NQE.Process (Inbox, inboxToMailbox, send)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, orElse, putTMVar, readTMVar, retry, throwSTM)
import Control.Exception qualified as IOException
import Effectful (Eff, IOE, UnliftStrategy (..), liftIO, withEffToIO, (:>))
import Effectful.Dispatch.Static (unEff, unsafeEff)
import Effectful.Exception qualified as Exception
import OpenTelemetry.Context qualified as TraceContext
import OpenTelemetry.Context.ThreadLocal qualified as TraceContext
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Metrics (MetricsHandle, ProcessorId (..), incrementReceived)
import Shibuya.Internal.Runner.Pause (PauseHandle, waitWhilePaused)
import Shibuya.Telemetry.Effect (Tracing, getTracer, isTracingEnabled)
import Shibuya.Telemetry.Semantic (attrShibuyaProcessorId, ingestSpanName, internalSpanArgs)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO qualified as UIO

-- | Run the ingester: reads from stream, sends to inbox.
-- Sends each element to the inbox with backpressure - if inbox is full, blocks.
-- Completes when the stream completes.
runIngester ::
  (IOE :> es) =>
  -- | Source stream from adapter
  Stream (Eff es) (Ingested es msg) ->
  -- | Target inbox (bounded for backpressure)
  Inbox (Ingested es msg) ->
  Eff es ()
runIngester source inbox = do
  let mailbox = inboxToMailbox inbox
  -- Send each stream element to the mailbox, then drain
  -- This provides backpressure: if mailbox is full (bounded), send blocks
  Stream.fold Fold.drain $
    Stream.mapM
      (\msg -> send msg mailbox >> pure msg)
      source

-- | Run the ingester with metrics tracking.
-- Increments the received count for each message sent to inbox.
runIngesterWithMetrics ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  -- | Metrics handle (for updating received count)
  MetricsHandle ->
  PauseHandle ->
  -- | Source stream from adapter
  Stream (Eff es) (Ingested es msg) ->
  -- | Target inbox (bounded for backpressure)
  Inbox (Ingested es msg) ->
  Eff es ()
runIngesterWithMetrics procId metricsHandle pauseHandle source inbox =
  traceIngestion procId $
    -- The fold and admission check use IO directly, avoiding an Eff action
    -- allocation for each step. Safe use of unsafeEff: IOE is required, and
    -- only this sequential fold calls unEff, on the owning ingester thread.
    -- The fold neither forks nor exports this environment or callback.
    unsafeEff $ \environment -> do
      let mailbox = inboxToMailbox inbox
      Stream.fold Fold.drain $
        Stream.mapM
          ( \msg -> do
              incrementReceived metricsHandle
              send msg mailbox
              pure msg
          )
          (Stream.morphInner (\step -> waitWhilePaused pauseHandle >> unEff step environment) source)

-- | Metrics and tracing for an intake that has no live pause capability.
runIngesterWithMetricsUnpaused ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  MetricsHandle ->
  Stream (Eff es) (Ingested es msg) ->
  Inbox (Ingested es msg) ->
  Eff es ()
runIngesterWithMetricsUnpaused procId metricsHandle source inbox =
  traceIngestion procId ingest
  where
    ingest = do
      let mailbox = inboxToMailbox inbox
      Stream.fold Fold.drain $
        Stream.mapM
          ( \msg -> do
              liftIO $ incrementReceived metricsHandle
              liftIO $ send msg mailbox
              pure msg
          )
          source

traceIngestion ::
  (IOE :> es, Tracing :> es) =>
  ProcessorId ->
  Eff es () ->
  Eff es ()
traceIngestion procId action = do
  enabled <- isTracingEnabled
  if not enabled
    then action
    else do
      tracer <- getTracer
      -- Only the owner unlifts source effects. The SDK worker is entirely IO,
      -- so a sequential unlift preserves the source's thread and local state.
      withEffToIO SeqUnlift $ \runInIO -> UIO.mask $ \restore -> do
        context <- TraceContext.getContext
        ready <- newEmptyTMVarIO
        finished <- newEmptyTMVarIO
        -- SDK callbacks catch cancellation. Isolate them from source ownership:
        -- after cancellation the worker can only observe the published outcome,
        -- never enter the source even if onStart consumes its cancellation.
        let trace = UIO.bracket (TraceContext.attachContext context) TraceContext.detachContext $ \_ ->
              OTel.inSpan' tracer ingestSpanName internalSpanArgs $ \sp -> do
                OTel.addAttribute sp attrShibuyaProcessorId procId.unProcessorId
                atomically $ putTMVar ready sp
                result <- atomically $ readTMVar finished
                either IOException.throwIO pure result
        UIO.withAsync trace $ \worker -> do
          result <- IOException.try @IOException.SomeException $ restore $ do
            sp <- atomically $ readTMVar ready `orElse` (Async.waitCatchSTM worker >>= either throwSTM (const retry))
            UIO.bracket (TraceContext.attachContext $ TraceContext.insertSpan sp context) TraceContext.detachContext $ \_ ->
              runInIO action
          atomically $ putTMVar finished result
          case result of
            -- withAsync still cancels and joins the worker on this path.
            Left failure | Exception.isAsyncException failure -> IOException.throwIO failure
            _ -> do
              traced <- restore $ UIO.waitCatch worker
              either IOException.throwIO (const $ either IOException.throwIO pure traced) result
