{-# LANGUAGE OverloadedStrings #-}

module Shibuya.RunnerSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck (..), newTrackingAck, trackingAckHandle)
import Shibuya.App (AppError (..), QueueProcessor (..), SupervisionStrategy (..), mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Error (PolicyError (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import Prelude hiding (Ordering)

spec :: Spec
spec = do
  describe "runApp" $ do
    it "processes messages from mock adapter" $ do
      result <- runEff $ runTracingNoop $ do
        -- Track processed messages
        processedRef <- liftIO $ newIORef ([] :: [String])

        -- Create test messages
        messages <- createTestMessages 3

        -- Create adapter and handler
        let adapter = testAdapter messages
            handler = testHandler processedRef
            processor = mkProcessor adapter handler

        -- Run the app
        res <-
          runApp
            IgnoreFailures
            100
            [ (ProcessorId "test", processor)
            ]

        case res of
          Left err -> pure $ Left err
          Right appHandle -> do
            waitApp appHandle
            pure $ Right ()

      -- Verify result
      result `shouldBe` Right ()

    it "calls finalize for each message" $ do
      (decisions, result) <- runEff $ runTracingNoop $ do
        -- Track ack decisions
        tracking <- newTrackingAck

        -- Create test messages with tracking acks
        messages <- createTrackedMessages tracking 3

        -- Create adapter and handler
        let adapter = testAdapter messages
            handler = alwaysAckOk
            processor = mkProcessor adapter handler

        -- Run the app
        res <-
          runApp
            IgnoreFailures
            100
            [ (ProcessorId "test", processor)
            ]

        case res of
          Left err -> do
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (decs, Left err)
          Right appHandle -> do
            waitApp appHandle
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (decs, Right ())

      -- Verify all messages were acked
      result `shouldBe` Right ()
      length decisions `shouldBe` 3
      -- All should be AckOk (decisions are in reverse order)
      all ((== AckOk) . snd) decisions `shouldBe` True

    it "returns AppHandle for multiple processors" $ do
      result <- runEff $ runTracingNoop $ do
        messages1 <- createTestMessages 2
        messages2 <- createTestMessages 2

        let adapter1 = testAdapter messages1
            adapter2 = testAdapter messages2
            handler = alwaysAckOk
            proc1 = mkProcessor adapter1 handler
            proc2 = mkProcessor adapter2 handler

        res <-
          runApp
            IgnoreFailures
            100
            [ (ProcessorId "proc1", proc1),
              (ProcessorId "proc2", proc2)
            ]

        case res of
          Left err -> pure $ Left err
          Right appHandle -> do
            waitApp appHandle
            pure $ Right ()

      result `shouldBe` Right ()

  describe "Policy validation" $ do
    it "rejects StrictInOrder with Async" $ do
      result <- runEff $ runTracingNoop $ do
        messages <- createTestMessages 3
        let adapter = testAdapter messages
            handler = alwaysAckOk
            -- Invalid combination: StrictInOrder requires Serial
            processor = QueueProcessor adapter handler StrictInOrder (Async 5)

        runApp IgnoreFailures 100 [(ProcessorId "invalid", processor)]

      case result of
        Left (AppPolicyError (InvalidPolicyCombo _)) -> pure ()
        Left err -> expectationFailure $ "Expected AppPolicyError, got: " ++ show err
        Right _ -> expectationFailure "Expected policy validation to fail"

    it "rejects StrictInOrder with Ahead" $ do
      result <- runEff $ runTracingNoop $ do
        messages <- createTestMessages 3
        let adapter = testAdapter messages
            handler = alwaysAckOk
            processor = QueueProcessor adapter handler StrictInOrder (Ahead 5)

        runApp IgnoreFailures 100 [(ProcessorId "invalid", processor)]

      case result of
        Left (AppPolicyError (InvalidPolicyCombo _)) -> pure ()
        Left err -> expectationFailure $ "Expected AppPolicyError, got: " ++ show err
        Right _ -> expectationFailure "Expected policy validation to fail"

    it "accepts valid policy combinations" $ do
      result <- runEff $ runTracingNoop $ do
        messages <- createTestMessages 2
        let adapter = testAdapter messages
            handler = alwaysAckOk
            -- Valid combinations
            proc1 = QueueProcessor adapter handler Unordered (Async 3)
            proc2 = QueueProcessor adapter handler PartitionedInOrder (Ahead 3)

        res <-
          runApp
            IgnoreFailures
            100
            [ (ProcessorId "async", proc1),
              (ProcessorId "ahead", proc2)
            ]
        case res of
          Left err -> pure $ Left err
          Right appHandle -> do
            waitApp appHandle
            pure $ Right ()

      result `shouldBe` Right ()

  describe "mkProcessor" $ do
    it "creates processor with Unordered ordering" $ do
      messages <- runEff $ createTestMessages 1
      let adapter = testAdapter messages
          handler = alwaysAckOk
          QueueProcessor _ _ ordering _ = mkProcessor adapter handler
      ordering `shouldBe` Unordered

    it "creates processor with Serial concurrency" $ do
      messages <- runEff $ createTestMessages 1
      let adapter = testAdapter messages
          handler = alwaysAckOk
          QueueProcessor _ _ _ concurrency = mkProcessor adapter handler
      concurrency `shouldBe` Serial

-- Test helpers

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2024 1 1) 0

-- | Create N test messages with simple string payloads
createTestMessages :: (IOE :> es) => Int -> Eff es [Ingested es String]
createTestMessages n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId = MessageId $ "msg-" <> (if i < 10 then "0" else "") <> Text.pack (show i)
          env =
            Envelope
              { messageId = msgId,
                cursor = Just (CursorInt i),
                partition = Nothing,
                enqueuedAt = Just testTime,
                traceContext = Nothing,
                payload = "message-" <> show i
              }
          ackHandle = AckHandle $ \_ -> pure () -- No-op ack
      pure $
        Ingested
          { envelope = env,
            ack = ackHandle,
            lease = Nothing
          }

-- | Create N test messages with tracking acks
createTrackedMessages :: (IOE :> es) => TrackingAck -> Int -> Eff es [Ingested es String]
createTrackedMessages tracking n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId = MessageId $ "msg-" <> (if i < 10 then "0" else "") <> Text.pack (show i)
          env =
            Envelope
              { messageId = msgId,
                cursor = Just (CursorInt i),
                partition = Nothing,
                enqueuedAt = Just testTime,
                traceContext = Nothing,
                payload = "message-" <> show i
              }
          ackHandle = trackingAckHandle tracking msgId
      pure $
        Ingested
          { envelope = env,
            ack = ackHandle,
            lease = Nothing
          }

-- | Create a test adapter from a list of messages
testAdapter :: [Ingested es String] -> Adapter es String
testAdapter messages =
  Adapter
    { adapterName = "test:mock",
      source = Stream.fromList messages,
      shutdown = pure ()
    }

-- | Handler that records processed messages
testHandler :: (IOE :> es) => IORef [String] -> Handler es String
testHandler ref ingested = do
  liftIO $ modifyIORef' ref (ingested.envelope.payload :)
  pure AckOk

-- | Handler that always returns AckOk
alwaysAckOk :: Handler es msg
alwaysAckOk _ = pure AckOk
