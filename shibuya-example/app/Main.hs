-- | Example demonstrating Shibuya with an infinite stream.
-- Creates a simple counter that generates messages indefinitely,
-- with a handler that prints each value to the terminal.
module Main (main) where

import Data.Function ((&))
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

-- | Create an adapter that produces an infinite stream of counter messages.
-- Each message contains an incrementing integer.
infiniteCounterAdapter :: (IOE :> es) => TrackingAck -> Adapter es Int
infiniteCounterAdapter tracking =
  Adapter
    { adapterName = "example:infinite-counter",
      source = Stream.unfold Unfold.fromList [0 ..] & Stream.mapM (mkIngested tracking),
      shutdown = liftIO $ Text.putStrLn "Shutting down infinite counter adapter"
    }

-- | Create an Ingested message from a counter value.
mkIngested :: (IOE :> es) => TrackingAck -> Int -> Eff es (Ingested es Int)
mkIngested tracking n = do
  let msgId = MessageId $ "msg-" <> Text.pack (show n)
  pure
    Ingested
      { envelope =
          Envelope
            { messageId = msgId,
              cursor = Nothing,
              partition = Nothing,
              enqueuedAt = Nothing,
              payload = n
            },
        ack = trackingAckHandle tracking msgId,
        lease = Nothing
      }

-- | Handler that prints each message to the terminal.
printHandler :: (IOE :> es) => Handler es Int
printHandler ingested = do
  liftIO $ Text.putStrLn $ "Processing message: " <> Text.pack (show ingested.envelope.payload)
  pure AckOk

main :: IO ()
main = runEff $ do
  liftIO $ Text.putStrLn "Starting Shibuya example with infinite stream..."

  -- Create tracking for ack decisions
  tracking <- newTrackingAck

  -- Create the adapter and run the app
  let adapter = infiniteCounterAdapter tracking
      config = defaultRunnerConfig adapter printHandler

  result <- runApp config

  case result of
    Left err -> liftIO $ Text.putStrLn $ "Error: " <> Text.pack (show err)
    Right () -> liftIO $ Text.putStrLn "Completed successfully"
