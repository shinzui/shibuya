-- | Example demonstrating Shibuya with multiple infinite streams.
-- Shows how to merge multiple adapters so a single worker
-- can process messages from different queues.
module Main (main) where

import Data.Function ((&))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck, newTrackingAck, trackingAckHandle)
import Shibuya.App (runApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Runner (defaultRunnerConfig)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Unfold qualified as Unfold

-- | Tagged message that identifies which queue it came from.
data TaggedMessage = TaggedMessage
  { source :: !Text,
    value :: !Int
  }
  deriving stock (Show)

-- | Merge multiple adapters into one.
-- Messages from all adapters are interleaved in the output stream.
mergeAdapters :: [Adapter es msg] -> Adapter es msg
mergeAdapters adapters =
  Adapter
    { adapterName = "merged:" <> Text.intercalate "+" (map (.adapterName) adapters),
      source = Stream.concatMap (.source) (Stream.fromList adapters),
      shutdown = mapM_ (.shutdown) adapters
    }

-- | Create an adapter that produces an infinite stream of counter messages.
-- Each message contains an incrementing integer starting from 0.
counterAdapter :: (IOE :> es) => TrackingAck -> Adapter es TaggedMessage
counterAdapter tracking =
  Adapter
    { adapterName = "counter",
      source =
        Stream.unfold Unfold.fromList [0 ..]
          & Stream.mapM (mkIngested tracking "counter"),
      shutdown = liftIO $ Text.putStrLn "Shutting down counter adapter"
    }

-- | Create an adapter that produces an infinite stream of "events".
-- Generates negative numbers to distinguish from the counter.
eventsAdapter :: (IOE :> es) => TrackingAck -> Adapter es TaggedMessage
eventsAdapter tracking =
  Adapter
    { adapterName = "events",
      source =
        Stream.unfold Unfold.fromList [-1, -2 ..]
          & Stream.mapM (mkIngested tracking "events"),
      shutdown = liftIO $ Text.putStrLn "Shutting down events adapter"
    }

-- | Create an Ingested message from a value.
mkIngested ::
  (IOE :> es) =>
  TrackingAck ->
  Text ->
  Int ->
  Eff es (Ingested es TaggedMessage)
mkIngested tracking sourceName n = do
  let msgId = MessageId $ sourceName <> "-" <> Text.pack (show (abs n))
  pure
    Ingested
      { envelope =
          Envelope
            { messageId = msgId,
              cursor = Nothing,
              partition = Nothing,
              enqueuedAt = Nothing,
              payload = TaggedMessage {source = sourceName, value = n}
            },
        ack = trackingAckHandle tracking msgId,
        lease = Nothing
      }

-- | Handler that prints each message with its source.
printHandler :: (IOE :> es) => Handler es TaggedMessage
printHandler ingested = do
  let msg = ingested.envelope.payload
  liftIO $
    Text.putStrLn $
      "[" <> msg.source <> "] Processing: " <> Text.pack (show msg.value)
  pure AckOk

main :: IO ()
main = runEff $ do
  liftIO $ Text.putStrLn "Starting Shibuya example with multiple queues..."
  liftIO $ Text.putStrLn "Press Ctrl+C to stop.\n"

  -- Create tracking for ack decisions
  tracking <- newTrackingAck

  -- Create multiple adapters and merge them
  let counter = counterAdapter tracking
      events = eventsAdapter tracking
      merged = mergeAdapters [counter, events]
      config = defaultRunnerConfig merged printHandler

  result <- runApp config

  case result of
    Left err -> liftIO $ Text.putStrLn $ "Error: " <> Text.pack (show err)
    Right () -> liftIO $ Text.putStrLn "Completed successfully"
