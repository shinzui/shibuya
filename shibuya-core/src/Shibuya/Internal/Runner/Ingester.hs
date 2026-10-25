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

import Control.Concurrent.NQE.Process (Inbox, inboxToMailbox, send)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Static (unEff, unsafeEff)
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Metrics (MetricsHandle, ProcessorId (..), incrementReceived)
import Shibuya.Internal.Runner.Pause (PauseHandle, waitWhilePaused)
import Shibuya.Telemetry.Effect (Tracing, addAttribute, withSpan')
import Shibuya.Telemetry.Semantic (attrShibuyaProcessorId, ingestSpanName, internalSpanArgs)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

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
traceIngestion procId action =
  withSpan' ingestSpanName internalSpanArgs $ \sp -> do
    addAttribute sp attrShibuyaProcessorId procId.unProcessorId
    action
