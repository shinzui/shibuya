-- | Processor - receives from inbox, calls handler, finalizes ack.
-- Runs in a loop until terminated.
module Shibuya.Runner.Processor
  ( runProcessor,
    runProcessorN,
    drainInbox,
  )
where

import Control.Concurrent.NQE.Process (Inbox, mailboxEmpty, receive)
import Control.Monad (forever, unless)
import Effectful (Eff, IOE, (:>))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Handler (Handler)

-- | Run the processor forever: receive message, call handler, finalize ack.
-- This runs until an exception is thrown or the thread is cancelled.
runProcessor ::
  (IOE :> es) =>
  -- | Message handler
  Handler es msg ->
  -- | Source inbox
  Inbox (Ingested es msg) ->
  Eff es ()
runProcessor handler inbox = forever $ processOne handler inbox

-- | Run the processor for exactly N messages.
-- Useful for testing.
runProcessorN ::
  (IOE :> es) =>
  -- | Number of messages to process
  Int ->
  -- | Message handler
  Handler es msg ->
  -- | Source inbox
  Inbox (Ingested es msg) ->
  Eff es ()
runProcessorN n handler inbox = go n
  where
    go 0 = pure ()
    go remaining = do
      processOne handler inbox
      go (remaining - 1)

-- | Process a single message: receive, handle, finalize.
processOne ::
  (IOE :> es) =>
  Handler es msg ->
  Inbox (Ingested es msg) ->
  Eff es ()
processOne handler inbox = do
  -- Receive next message (blocks if inbox empty)
  ingested <- receive inbox

  -- Call the handler to get the ack decision
  decision <- handler ingested

  -- Finalize the ack (commit, retry, dead-letter, or halt)
  -- Note: AckHalt is handled by the supervised runner (Supervised.hs throws ProcessorHalt)
  ingested.ack.finalize decision

-- | Drain all remaining messages from inbox until empty.
-- Used after ingester completes to process buffered messages.
drainInbox ::
  (IOE :> es) =>
  -- | Message handler
  Handler es msg ->
  -- | Source inbox
  Inbox (Ingested es msg) ->
  Eff es ()
drainInbox handler inbox = go
  where
    go = do
      empty <- mailboxEmpty inbox
      unless empty $ do
        processOne handler inbox
        go
