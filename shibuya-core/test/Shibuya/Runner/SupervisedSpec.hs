{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Runner.SupervisedSpec (spec) where

import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Runner.Master
  ( Master,
    getAllMetrics,
    getProcessorMetrics,
    startMaster,
    stopMaster,
  )
import Shibuya.Runner.Metrics
  ( ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )
import Shibuya.Runner.Supervised
  ( SupervisedProcessor (..),
    getMetrics,
    getProcessorState,
    isDone,
    runWithMetrics,
  )
import Streamly.Data.Stream qualified as Stream
import Test.Hspec

spec :: Spec
spec = do
  describe "Shibuya.Runner.Master" $ do
    it "starts and stops cleanly" $ do
      result <- runEff $ do
        master <- startMaster IgnoreAll
        stopMaster master
        pure ()
      result `shouldBe` ()

    it "returns empty metrics initially" $ do
      metrics <- runEff $ do
        master <- startMaster IgnoreAll
        m <- getAllMetrics master
        stopMaster master
        pure m
      metrics `shouldSatisfy` null

  describe "Shibuya.Runner.Supervised" $ do
    describe "runWithMetrics" $ do
      it "processes messages and tracks metrics" $ do
        (finalMetrics, processedMsgs) <- runEff $ do
          -- Track processed messages
          processedRef <- liftIO $ newIORef ([] :: [String])

          -- Create test messages
          messages <- createTestMessages 3

          -- Create adapter and handler
          let adapter = testAdapter messages
              handler = testHandler processedRef
              procId = ProcessorId "test-processor"

          -- Run with metrics
          sp <- runWithMetrics 10 procId adapter handler

          -- Get results
          metrics <- getMetrics sp
          msgs <- liftIO $ readIORef processedRef
          pure (metrics, msgs)

        -- Verify metrics
        finalMetrics.stats.received `shouldBe` 3
        finalMetrics.stats.processed `shouldBe` 3
        finalMetrics.stats.failed `shouldBe` 0
        finalMetrics.state `shouldBe` Idle

        -- Verify all messages were processed
        length processedMsgs `shouldBe` 3

      it "tracks failed messages" $ do
        finalMetrics <- runEff $ do
          messages <- createTestMessages 3

          let adapter = testAdapter messages
              handler = failingHandler
              procId = ProcessorId "failing-processor"

          sp <- runWithMetrics 10 procId adapter handler
          getMetrics sp

        -- All should be failed (handler throws)
        finalMetrics.stats.failed `shouldBe` 3

      it "marks processor as done when stream exhausted" $ do
        done <- runEff $ do
          messages <- createTestMessages 2

          let adapter = testAdapter messages
              handler = alwaysAckOk
              procId = ProcessorId "quick-processor"

          sp <- runWithMetrics 10 procId adapter handler
          isDone sp

        done `shouldBe` True

-- Test helpers

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2024 1 1) 0

createTestMessages :: (IOE :> es) => Int -> Eff es [Ingested es String]
createTestMessages n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId = MessageId $ "msg-" <> Text.pack (show i)
          env =
            Envelope
              { messageId = msgId,
                cursor = Just (CursorInt i),
                partition = Nothing,
                enqueuedAt = Just testTime,
                payload = "message-" <> show i
              }
          ackHandle = AckHandle $ \_ -> pure ()
      pure $
        Ingested
          { envelope = env,
            ack = ackHandle,
            lease = Nothing
          }

testAdapter :: [Ingested es String] -> Adapter es String
testAdapter messages =
  Adapter
    { adapterName = "test:supervised",
      source = Stream.fromList messages,
      shutdown = pure ()
    }

testHandler :: (IOE :> es) => IORef [String] -> Handler es String
testHandler ref ingested = do
  liftIO $ modifyIORef' ref (ingested.envelope.payload :)
  pure AckOk

failingHandler :: Handler es msg
failingHandler _ = error "Intentional failure"

alwaysAckOk :: Handler es msg
alwaysAckOk _ = pure AckOk
