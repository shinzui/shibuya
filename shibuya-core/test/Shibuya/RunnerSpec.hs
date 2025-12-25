{-# LANGUAGE OverloadedStrings #-}

module Shibuya.RunnerSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck (..), newTrackingAck, trackingAckHandle)
import Shibuya.App (AppError (..), runApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Shibuya.Runner (RunnerConfig (..), defaultRunnerConfig)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import Prelude hiding (Ordering)

spec :: Spec
spec = do
  describe "runApp" $ do
    it "processes messages from mock adapter" $ do
      result <- runEff $ do
        -- Track processed messages
        processedRef <- liftIO $ newIORef ([] :: [String])

        -- Create test messages
        messages <- createTestMessages 3

        -- Create adapter and handler
        let adapter = testAdapter messages
            handler = testHandler processedRef

        -- Run the app
        runApp $ defaultRunnerConfig adapter handler

      -- Verify result
      result `shouldBe` Right ()

    it "calls finalize for each message" $ do
      (decisions, result) <- runEff $ do
        -- Track ack decisions
        tracking <- newTrackingAck

        -- Create test messages with tracking acks
        messages <- createTrackedMessages tracking 3

        -- Create adapter and handler
        let adapter = testAdapter messages
            handler = alwaysAckOk

        -- Run the app
        res <- runApp $ defaultRunnerConfig adapter handler

        -- Get tracked decisions
        decs <- liftIO $ readIORef tracking.trackedDecisions
        pure (decs, res)

      -- Verify all messages were acked
      result `shouldBe` Right ()
      length decisions `shouldBe` 3
      -- All should be AckOk (decisions are in reverse order)
      all ((== AckOk) . snd) decisions `shouldBe` True

    it "rejects invalid policy" $ do
      result <- runEff $ do
        messages <- createTestMessages 1
        let adapter = testAdapter messages
            handler = alwaysAckOk
            config =
              (defaultRunnerConfig adapter handler)
                { ordering = StrictInOrder,
                  concurrency = Async 4 -- Invalid: StrictInOrder requires Serial
                }
        runApp config

      case result of
        Left (PolicyValidationError _) -> pure ()
        other -> expectationFailure $ "Expected PolicyValidationError, got: " ++ show other

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
