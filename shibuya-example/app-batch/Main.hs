-- | Runnable example of first-class batch processing in Shibuya.
--
-- Feeds five sample orders through one batching processor. Orders are grouped
-- into sub-batches by region (the batch key). With batchSize = 2, the "us" and
-- "eu" regions each fill a batch of two (emitted by TriggerSize); the single
-- "apac" order is left partial and is flushed on shutdown (TriggerFlush). One
-- order is a "poison" order that the batch handler dead-letters, demonstrating
-- a partial failure inside an otherwise-successful batch.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Monad (forM_, void)
import Data.HashMap.Strict qualified as HashMap
import Data.List.NonEmpty qualified as NonEmpty
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
    defaultAppConfig,
    getAppMetrics,
    mkBatchProcessor,
    runApp,
    stopApp,
  )
import Shibuya.Batch
  ( BatchConfig (..),
    BatchHandler,
    BatchInfo (..),
    BatchKey (..),
    ackAllOk,
    defaultBatchConfig,
    failMessages,
  )
import Shibuya.Core.Ack (DeadLetterReason (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Metrics (BatchStats (..), StreamStats (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream

-- | The example payload. 'region' becomes the batch key; 'poison' orders are
-- dead-lettered by the batch handler.
data Order = Order
  { orderId :: !Int,
    region :: !Text,
    poison :: !Bool
  }
  deriving stock (Eq, Show)

-- | Five orders: "us" = [10,11], "eu" = [20,21], "apac" = [30].
-- Order 21 is poison. With batchSize = 2 the us and eu batches fill by size;
-- the single apac order stays partial until the shutdown flush.
sampleOrders :: [Order]
sampleOrders =
  [ Order 10 "us" False,
    Order 11 "us" False,
    Order 20 "eu" False,
    Order 21 "eu" True,
    Order 30 "apac" False
  ]

-- | Wrap an 'Order' in an 'Ingested' message with a tracking ack handle.
mkIngested :: (IOE :> es) => TrackingAck -> Order -> Ingested es Order
mkIngested tracking o =
  let msgId = MessageId ("order-" <> Text.pack (show o.orderId))
   in Ingested
        { envelope =
            Envelope
              { messageId = msgId,
                cursor = Nothing,
                partition = Just o.region,
                enqueuedAt = Nothing,
                traceContext = Nothing,
                headers = Nothing,
                attempt = Nothing,
                attributes = HashMap.empty,
                payload = o
              },
          ack = trackingAckHandle tracking msgId,
          lease = Nothing
        }

-- | Adapter that emits the five orders and then blocks until 'shutdown' fills
-- the MVar. Blocking (rather than ending the stream) keeps the partial "apac"
-- batch pending so that 'stopApp' is what flushes it. Implemented as an unfold
-- that yields each ingested order and, once the list is exhausted, blocks on the
-- stop MVar before ending the stream.
ordersAdapter :: (IOE :> es) => TrackingAck -> MVar () -> [Order] -> Adapter es Order
ordersAdapter tracking stopVar orders =
  Adapter
    { adapterName = "orders",
      source = Stream.unfoldrM step orders,
      shutdown = do
        liftIO $ Text.putStrLn "Shutting down orders adapter"
        liftIO $ void (tryPutMVar stopVar ())
    }
  where
    step [] = do
      liftIO $ readMVar stopVar
      pure Nothing
    step (o : os) = pure (Just (mkIngested tracking o, os))

-- | Batch configuration: group by region, two per batch, a long timeout so the
-- timeout trigger never fires during this short run.
batchCfg :: BatchConfig es Order
batchCfg =
  defaultBatchConfig
    { batchSize = 2,
      batchTimeout = 60,
      batchKey = \env -> BatchKey env.payload.region
    }

-- | Simulate a bulk downstream write: print one line per emitted batch, then
-- dead-letter any poison order and ack the rest OK.
batchHandler :: (IOE :> es) => BatchHandler es Order
batchHandler info msgs = do
  liftIO $
    Text.putStrLn $
      "flushed batch of "
        <> Text.pack (show info.size)
        <> " messages (key="
        <> info.batchKey.unBatchKey
        <> ", trigger="
        <> Text.pack (show info.trigger)
        <> ")"
  let poisoned =
        [ (ing.envelope.messageId, PoisonPill "poison order")
        | ing <- NonEmpty.toList msgs,
          ing.envelope.payload.poison
        ]
  case poisoned of
    [] -> pure ackAllOk
    ps -> do
      forM_ ps $ \(MessageId m, _) ->
        liftIO $ Text.putStrLn $ "  -> dead-lettered " <> m
      pure (failMessages ps)

-- | Print per-message and batch counters for every processor.
printMetrics :: (IOE :> es) => Text -> AppHandle es -> Eff es ()
printMetrics label appHandle = do
  metrics <- getAppMetrics appHandle
  liftIO $ Text.putStrLn ("--- Metrics " <> label <> " ---")
  liftIO $ forM_ (Map.toList metrics) $ \(ProcessorId name, pm) -> do
    Text.putStrLn $
      name
        <> ": received="
        <> Text.pack (show pm.stats.received)
        <> " processed="
        <> Text.pack (show pm.stats.processed)
        <> " failed="
        <> Text.pack (show pm.stats.failed)
    Text.putStrLn $
      "  batches="
        <> Text.pack (show pm.batch.batchesEmitted)
        <> " batchedMessages="
        <> Text.pack (show pm.batch.batchedMessages)
        <> " partialFailures="
        <> Text.pack (show pm.batch.partialFailures)
        <> " bySize="
        <> Text.pack (show pm.batch.sizeTriggered)
        <> " byTimeout="
        <> Text.pack (show pm.batch.timeoutTriggered)
        <> " byFlush="
        <> Text.pack (show pm.batch.flushTriggered)

main :: IO ()
main = runEff $ runTracingNoop app

app :: Eff '[Tracing, IOE] ()
app = do
  liftIO $ Text.putStrLn "=== Shibuya batch processing example ==="
  liftIO $ Text.putStrLn "Feeding 5 orders (batchSize=2, batched by region) through a batching processor."

  tracking <- newTrackingAck
  stopVar <- liftIO newEmptyMVar
  let adapter = ordersAdapter tracking stopVar sampleOrders
      processor = mkBatchProcessor adapter batchHandler batchCfg

  result <-
    runApp
      defaultAppConfig
      [(ProcessorId "orders", processor)]

  case result of
    Left err ->
      liftIO $ Text.putStrLn $ "Startup error: " <> Text.pack (show err)
    Right appHandle -> do
      -- Give the two size-triggered batches time to emit and print.
      liftIO $ threadDelay 500_000
      printMetrics "after size-triggered batches" appHandle

      liftIO $ Text.putStrLn "Stopping (flushes the final partial batch)..."
      _ <- stopApp appHandle
      liftIO $ Text.putStrLn "Done!"
