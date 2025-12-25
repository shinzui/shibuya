-- | Ingester - reads from adapter stream and sends to inbox.
-- Provides backpressure via bounded inbox.
module Shibuya.Runner.Ingester
  ( runIngester,
  )
where

import Control.Concurrent.NQE.Process (Inbox, inboxToMailbox, send)
import Effectful (Eff, IOE, (:>))
import Shibuya.Core.Ingested (Ingested)
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
