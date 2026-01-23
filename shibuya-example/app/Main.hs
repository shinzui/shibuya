-- | Example demonstrating Shibuya with multiple independent queues.
-- Each queue runs as a separate supervised processor, showing how
-- a single application can process messages from different sources concurrently.
-- This example also shows how to retrieve and display metrics.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_)
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck, newTrackingAck, trackingAckHandle)
import Shibuya.App
  ( AppHandle,
    ProcessorId (..),
    ProcessorMetrics (..),
    QueueProcessor (..),
    SupervisionStrategy (..),
    getAppMetrics,
    runApp,
    stopApp,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Runner.Metrics (ProcessorState (..), StreamStats (..))
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Unfold qualified as Unfold

-- | Create an adapter that produces an infinite stream of counter messages.
-- Each message contains an incrementing integer starting from the given value.
counterAdapter ::
  (IOE :> es) =>
  TrackingAck ->
  -- | Adapter name
  Text ->
  -- | Starting value
  Int ->
  -- | Step
  Int ->
  Adapter es Int
counterAdapter tracking name start step =
  Adapter
    { adapterName = name,
      source =
        Stream.unfold Unfold.fromList [start, start + step ..]
          & Stream.mapM (mkIngested tracking name),
      shutdown = liftIO $ Text.putStrLn $ "Shutting down " <> name <> " adapter"
    }

-- | Create an Ingested message from a value.
mkIngested ::
  (IOE :> es) =>
  TrackingAck ->
  Text ->
  Int ->
  Eff es (Ingested es Int)
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
              payload = n
            },
        ack = trackingAckHandle tracking msgId,
        lease = Nothing
      }

-- | Handler that prints each message with its source.
-- Includes a small delay to simulate real work and allow thread switching.
printHandler :: (IOE :> es) => Text -> Handler es Int
printHandler name ingested = do
  liftIO $
    Text.putStrLn $
      "[" <> name <> "] Processing: " <> Text.pack (show ingested.envelope.payload)
  liftIO $ threadDelay 1000 -- 1ms delay to simulate work
  pure AckOk

-- | Print metrics for all processors.
printMetrics :: (IOE :> es) => AppHandle es -> Eff es ()
printMetrics appHandle = do
  metrics <- getAppMetrics appHandle
  liftIO $ do
    Text.putStrLn "\n===== Processor Metrics ====="
    _ <- Map.traverseWithKey printProcessorMetrics metrics
    Text.putStrLn "============================\n"
  where
    printProcessorMetrics :: ProcessorId -> ProcessorMetrics -> IO ()
    printProcessorMetrics (ProcessorId name) pm = do
      Text.putStrLn $ "Processor: " <> name
      Text.putStrLn $ "  State:     " <> formatState pm.state
      Text.putStrLn $ "  Received:  " <> Text.pack (show pm.stats.received)
      Text.putStrLn $ "  Processed: " <> Text.pack (show pm.stats.processed)
      Text.putStrLn $ "  Dropped:   " <> Text.pack (show pm.stats.dropped)
      Text.putStrLn $ "  Failed:    " <> Text.pack (show pm.stats.failed)

    formatState :: ProcessorState -> Text
    formatState Idle = "Idle"
    formatState (Processing count _) = "Processing (" <> Text.pack (show count) <> " in flight)"
    formatState (Failed err _) = "Failed: " <> err
    formatState Stopped = "Stopped"

main :: IO ()
main = runEff $ do
  liftIO $ Text.putStrLn "Starting Shibuya example with multiple independent queues..."
  liftIO $ Text.putStrLn "Each queue runs as a separate supervised processor."
  liftIO $ Text.putStrLn "Will show metrics every second for 5 iterations.\n"

  -- Create tracking for ack decisions (shared for simplicity)
  tracking <- newTrackingAck

  -- Define our processors - each with its own adapter and handler
  let ordersProcessor =
        QueueProcessor
          { adapter = counterAdapter tracking "orders" 1 1, -- 1, 2, 3, ...
            handler = printHandler "orders"
          }

      eventsProcessor =
        QueueProcessor
          { adapter = counterAdapter tracking "events" 100 10, -- 100, 110, 120, ...
            handler = printHandler "events"
          }

  -- Run all processors concurrently under supervision
  result <-
    runApp
      IgnoreFailures -- Keep running even if a processor fails
      100 -- Inbox size
      [ (ProcessorId "orders", ordersProcessor),
        (ProcessorId "events", eventsProcessor)
      ]

  case result of
    Left err -> liftIO $ Text.putStrLn $ "Error: " <> Text.pack (show err)
    Right appHandle -> do
      liftIO $ Text.putStrLn "All processors started."

      -- Print metrics every second for 5 iterations
      replicateM_ 5 $ do
        liftIO $ threadDelay 1000000 -- 1 second
        printMetrics appHandle

      -- Gracefully stop all processors
      liftIO $ Text.putStrLn "Stopping processors..."
      stopApp appHandle
      liftIO $ Text.putStrLn "Done!"
