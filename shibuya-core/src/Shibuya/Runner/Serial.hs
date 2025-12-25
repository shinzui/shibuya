-- | Serial Runner - processes messages one at a time.
-- Simple sequential runner for ordered processing.
module Shibuya.Runner.Serial
  ( runSerial,
  )
where

import Effectful (Eff, IOE, (:>))
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Handler (Handler)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

-- | Run the serial runner.
-- Processes each message from the adapter stream sequentially:
-- 1. Pull message from stream
-- 2. Call handler
-- 3. Finalize ack
-- 4. Repeat until stream is exhausted
--
-- This is the simplest runner - no concurrency, no backpressure buffering.
-- Suitable for ordered, low-throughput workloads.
runSerial ::
  (IOE :> es) =>
  -- | Inbox size (unused in serial mode, for API compatibility)
  Natural ->
  -- | Queue adapter
  Adapter es msg ->
  -- | Message handler
  Handler es msg ->
  Eff es ()
runSerial _inboxSize adapter handler = do
  -- Process each message from the stream sequentially
  Stream.fold Fold.drain $
    Stream.mapM processOne adapter.source
  where
    processOne ingested = do
      -- Call the handler to get the ack decision
      decision <- handler ingested
      -- Finalize the ack
      ingested.ack.finalize decision
