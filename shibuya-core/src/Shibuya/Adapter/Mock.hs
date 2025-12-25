-- | Mock adapter for testing.
-- Provides adapters that produce messages from in-memory sources.
module Shibuya.Adapter.Mock
  ( -- * Mock Adapters
    listAdapter,

    -- * Test Helpers
    TrackingAck (..),
    newTrackingAck,
    trackingAckHandle,
    getTrackedDecisions,
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Effectful (Eff, IOE, liftIO, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Types (MessageId (..))
import Streamly.Data.Stream qualified as Stream

-- | Create an adapter from a list of ingested messages.
-- Useful for testing handlers with predetermined input.
listAdapter :: (IOE :> es) => [Ingested es msg] -> Adapter es msg
listAdapter msgs =
  Adapter
    { adapterName = "mock:list",
      source = Stream.fromList msgs,
      shutdown = pure ()
    }

-- | Tracking state for ack decisions.
data TrackingAck = TrackingAck
  { trackedDecisions :: IORef [(MessageId, AckDecision)]
  }

-- | Create an AckHandle that tracks all decisions made.
-- Useful for testing that handlers make correct ack decisions.
trackingAckHandle ::
  (IOE :> es) =>
  TrackingAck ->
  MessageId ->
  AckHandle es
trackingAckHandle tracking msgId =
  AckHandle $ \decision ->
    liftIO $ modifyIORef' tracking.trackedDecisions ((msgId, decision) :)

-- | Create a new TrackingAck.
newTrackingAck :: (IOE :> es) => Eff es TrackingAck
newTrackingAck = liftIO $ TrackingAck <$> newIORef []

-- | Get all tracked decisions.
getTrackedDecisions :: (IOE :> es) => TrackingAck -> Eff es [(MessageId, AckDecision)]
getTrackedDecisions tracking = liftIO $ readIORef tracking.trackedDecisions
