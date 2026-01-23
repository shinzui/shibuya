{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Runner.SupervisedSpec (spec) where

import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Concurrent.STM (readTVarIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Runner.Halt (ProcessorHalt (..))
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
    runSupervised,
    runWithMetrics,
  )
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import UnliftIO (try)
import UnliftIO.Concurrent (threadDelay)

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

    describe "AckHalt behavior" $ do
      it "stops processing when handler returns AckHalt" $ do
        processedCount <- do
          processedRef <- newIORef (0 :: Int)

          let handler _ = do
                count <- liftIO $ readIORef processedRef
                liftIO $ modifyIORef' processedRef (+ 1)
                if count >= 2
                  then pure $ AckHalt (HaltFatal "stopping after 3")
                  else pure AckOk

          -- Try to run and catch ProcessorHalt
          result <- try $ runEff $ do
            messages <- createTestMessages 10
            let adapter = testAdapter messages
                procId = ProcessorId "halting-processor"
            runWithMetrics 10 procId adapter handler

          -- Verify ProcessorHalt was thrown
          case result of
            Left (ProcessorHalt reason) ->
              reason `shouldBe` HaltFatal "stopping after 3"
            Right _ ->
              expectationFailure "Expected ProcessorHalt exception"

          readIORef processedRef

        -- Should have processed exactly 3 messages before halt
        processedCount `shouldBe` 3

      it "updates metrics to halted state on AckHalt" $ do
        finalMetrics <- runEff $ do
          messages <- createTestMessages 5

          let handler _ = pure $ AckHalt (HaltFatal "immediate halt")
              adapter = testAdapter messages

          master <- startMaster IgnoreAll

          -- runSupervised catches ProcessorHalt, so we can check metrics
          sp <- runSupervised master 10 (ProcessorId "halt-metrics") adapter handler

          -- Wait for processor to halt
          liftIO $ threadDelay 100000 -- 100ms
          m <- liftIO $ readTVarIO sp.metrics
          stopMaster master
          pure m

        case finalMetrics.state of
          Failed msg _ -> msg `shouldSatisfy` (Text.isInfixOf "immediate halt")
          other -> expectationFailure $ "Expected Failed state, got: " ++ show other

      it "halt in one supervised processor doesn't affect others" $ do
        (countA, countB) <- runEff $ do
          countARef <- liftIO $ newIORef (0 :: Int)
          countBRef <- liftIO $ newIORef (0 :: Int)

          messagesA <- createTestMessages 10
          messagesB <- createTestMessages 10

          -- Handler A halts after 2 messages
          let handlerA _ = do
                count <- liftIO $ readIORef countARef
                liftIO $ modifyIORef' countARef (+ 1)
                if count >= 1
                  then pure $ AckHalt (HaltFatal "A stopping")
                  else pure AckOk

          -- Handler B processes all messages
          let handlerB _ = do
                liftIO $ modifyIORef' countBRef (+ 1)
                pure AckOk

          let adapterA = testAdapter messagesA
              adapterB = testAdapter messagesB

          master <- startMaster IgnoreAll

          _spA <- runSupervised master 10 (ProcessorId "A") adapterA handlerA
          _spB <- runSupervised master 10 (ProcessorId "B") adapterB handlerB

          -- Wait for both to complete
          liftIO $ threadDelay 500000 -- 500ms
          cA <- liftIO $ readIORef countARef
          cB <- liftIO $ readIORef countBRef

          stopMaster master
          pure (cA, cB)

        -- A should have stopped after 2 messages
        countA `shouldBe` 2
        -- B should have processed all 10
        countB `shouldBe` 10

-- Test helpers

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 1 1) 0

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
