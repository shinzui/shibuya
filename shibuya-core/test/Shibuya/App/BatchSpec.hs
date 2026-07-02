module Shibuya.App.BatchSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, writeTVar)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck (..), newTrackingAck, trackingAckHandle)
import Shibuya.App
  ( AppError (..),
    QueueProcessor (..),
    defaultAppConfig,
    mkBatchProcessor,
    runApp,
    stopApp,
    waitApp,
  )
import Shibuya.Batch
  ( BatchConfig (..),
    BatchHandler,
    BatchInfo (..),
    BatchTrigger (..),
    ackAllOk,
    defaultBatchConfig,
  )
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.App.Batch" $ do
  describe "runApp with a BatchingProcessor" $ do
    -- Milestone 1: a bad batch config is rejected by runApp with AppBatchConfigError.
    it "rejects a batch config with size 0 (AppBatchConfigError)" $ do
      result <- runEff $ runTracingNoop $ do
        sizeRef <- liftIO $ newIORef []
        tracking <- newTrackingAck
        messages <- createTrackedMessages tracking 1
        let adapter = listAdapter' messages
            badConfig = defaultBatchConfig {batchSize = 0}
            processor = mkBatchProcessor adapter (recordingHandler sizeRef) badConfig
        runApp defaultAppConfig [(ProcessorId "bad", processor)]
      case result of
        Left (AppBatchConfigError _) -> pure ()
        Left e -> expectationFailure ("expected AppBatchConfigError, got: " ++ show e)
        Right _ -> expectationFailure "expected Left, got a running AppHandle"

    it "rejects PartitionedInOrder with concurrent batching" $ do
      result <- runEff $ runTracingNoop $ do
        sizeRef <- liftIO $ newIORef []
        tracking <- newTrackingAck
        messages <- createTrackedMessages tracking 1
        let adapter = listAdapter' messages
            processor =
              BatchingProcessor
                adapter
                (recordingHandler sizeRef)
                defaultBatchConfig
                PartitionedInOrder
                (Async 2)
        runApp defaultAppConfig [(ProcessorId "bad-policy", processor)]
      case result of
        Left (AppPolicyError _) -> pure ()
        Left e -> expectationFailure ("expected AppPolicyError, got: " ++ show e)
        Right _ -> expectationFailure "expected Left, got a running AppHandle"

    -- Milestone 2: all N messages are acked exactly once, seen in batches.
    it "processes all messages in batches and acks each exactly once" $ do
      (sizes, ids) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        sizeRef <- liftIO $ newIORef []
        messages <- createTrackedMessages tracking 10
        let adapter = listAdapter' messages
            config = defaultBatchConfig {batchSize = 4, batchTimeout = 60}
            processor = mkBatchProcessor adapter (recordingHandler sizeRef) config
        res <- runApp defaultAppConfig [(ProcessorId "batch", processor)]
        case res of
          Left err -> liftIO $ ioError (userError (show err))
          Right appHandle -> do
            waitApp appHandle
            ss <- liftIO $ readIORef sizeRef
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (ss, map fst decs)
      sum (map fst sizes) `shouldBe` 10
      length ids `shouldBe` 10 -- normal path: each message finalized once
      length (nub ids) `shouldBe` 10 -- and all distinct

    -- Milestone 3: a partial batch (< batchSize, timeout far off) is flushed on shutdown.
    it "flushes a pending partial batch on graceful shutdown" $ do
      (sizes, ids, triggers) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        sizeRef <- liftIO $ newIORef []
        gate <- liftIO $ newTVarIO False
        messages <- createTrackedMessages tracking 3
        let adapter = gatedAdapter gate messages
            -- Never fills (size 100) and never times out during the test (60s).
            config = defaultBatchConfig {batchSize = 100, batchTimeout = 60}
            processor = mkBatchProcessor adapter (recordingHandler sizeRef) config
        res <- runApp defaultAppConfig [(ProcessorId "flush", processor)]
        case res of
          Left err -> liftIO $ ioError (userError (show err))
          Right appHandle -> do
            -- Let the 3 messages be ingested and accumulated.
            liftIO $ threadDelay 200000
            stopApp appHandle -- ends source -> EOF flush -> waits for done
            ss <- liftIO $ readIORef sizeRef
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (ss, map fst decs, map snd ss)
      sum (map fst sizes) `shouldBe` 3
      length ids `shouldBe` 3
      length (nub ids) `shouldBe` 3
      all (== TriggerFlush) triggers `shouldBe` True

-- Handler that records (batch size, trigger) and acks everything OK.
recordingHandler ::
  (IOE :> es) => IORef [(Int, BatchTrigger)] -> BatchHandler es String
recordingHandler ref info _batch = do
  liftIO $ modifyIORef' ref ((info.size, info.trigger) :)
  pure ackAllOk

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2024 1 1) 0

createTrackedMessages :: (IOE :> es) => TrackingAck -> Int -> Eff es [Ingested es String]
createTrackedMessages tracking n = mapM mk [1 .. n]
  where
    mk i = do
      let msgId = MessageId $ "msg-" <> (if i < 10 then "0" else "") <> Text.pack (show i)
          env =
            Envelope
              { messageId = msgId,
                cursor = Just (CursorInt i),
                partition = Nothing,
                enqueuedAt = Just testTime,
                traceContext = Nothing,
                headers = Nothing,
                attempt = Nothing,
                attributes = HashMap.empty,
                payload = "message-" <> show i
              }
      pure $ Ingested {envelope = env, ack = trackingAckHandle tracking msgId, lease = Nothing}

-- Finite adapter: ends as soon as its list is exhausted.
listAdapter' :: [Ingested es String] -> Adapter es String
listAdapter' messages =
  Adapter {adapterName = "test:batch", source = Stream.fromList messages, shutdown = pure ()}

-- Gated adapter: emits the messages, then blocks until 'shutdown' opens the gate,
-- so a partial batch stays pending until stopApp triggers the flush. Implemented
-- as an unfold that yields each message and, once the list is exhausted, blocks
-- on the gate before ending the stream.
gatedAdapter :: (IOE :> es) => TVar Bool -> [Ingested es String] -> Adapter es String
gatedAdapter gate messages =
  Adapter
    { adapterName = "test:gated",
      source = Stream.unfoldrM step messages,
      shutdown = liftIO $ atomically $ writeTVar gate True
    }
  where
    step [] = do
      waitGate
      pure Nothing
    step (m : ms) = pure (Just (m, ms))
    waitGate = liftIO $ atomically $ readTVar gate >>= check
