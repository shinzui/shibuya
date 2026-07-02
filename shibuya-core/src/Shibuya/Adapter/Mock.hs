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
    mkTrackedIngested,
    trackedListAdapter,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Effectful (Eff, IOE, liftIO, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
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
    liftIO $ atomicModifyIORef' tracking.trackedDecisions (\xs -> ((msgId, decision) : xs, ()))

-- | Create a new TrackingAck.
newTrackingAck :: (IOE :> es) => Eff es TrackingAck
newTrackingAck = liftIO $ TrackingAck <$> newIORef []

-- | Get all tracked decisions.
getTrackedDecisions :: (IOE :> es) => TrackingAck -> Eff es [(MessageId, AckDecision)]
getTrackedDecisions tracking = liftIO $ readIORef tracking.trackedDecisions

-- | Wrap an envelope into an 'Ingested' whose acknowledgement is recorded by the
-- given 'TrackingAck', keyed by the envelope's own 'MessageId'. The lease is
-- 'Nothing'. Every call to the resulting handle's 'finalize' appends one
-- @(messageId, decision)@ pair to the tracking list, so duplicate finalizes are
-- observable.
mkTrackedIngested :: (IOE :> es) => TrackingAck -> Envelope msg -> Ingested es msg
mkTrackedIngested tracking env =
  Ingested
    { envelope = env,
      ack = trackingAckHandle tracking env.messageId,
      lease = Nothing
    }

-- | Build an adapter from a list of envelopes where every message's acknowledgement
-- is recorded into one shared 'TrackingAck'. Combine with 'getTrackedDecisions' to
-- assert one successful finalization per message across a normal run.
trackedListAdapter :: (IOE :> es) => TrackingAck -> [Envelope msg] -> Adapter es msg
trackedListAdapter tracking envs =
  listAdapter (map (mkTrackedIngested tracking) envs)
