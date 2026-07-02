-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Ingester - reads from adapter stream and sends to inbox.
-- Provides backpressure via bounded inbox.
module Shibuya.Internal.Runner.Ingester
  ( runIngester,
    runIngesterWithMetrics,
  )
where

import Control.Concurrent.NQE.Process (Inbox, inboxToMailbox, send)
import Effectful (Eff, IOE, liftIO, (:>))
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Metrics (MetricsHandle, incrementReceived)
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
  (IOE :> es) =>
  -- | Metrics handle (for updating received count)
  MetricsHandle ->
  -- | Source stream from adapter
  Stream (Eff es) (Ingested es msg) ->
  -- | Target inbox (bounded for backpressure)
  Inbox (Ingested es msg) ->
  Eff es ()
runIngesterWithMetrics metricsHandle source inbox = do
  let mailbox = inboxToMailbox inbox
  Stream.fold Fold.drain $
    Stream.mapM
      ( \msg -> do
          -- Increment received count
          liftIO $ incrementReceived metricsHandle
          -- Send to inbox (blocks if full - backpressure)
          liftIO $ send msg mailbox
          pure msg
      )
      source
