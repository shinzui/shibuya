{-# LANGUAGE OverloadedStrings #-}

module Shibuya.RunnerSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (TrackingAck (..), newTrackingAck, trackingAckHandle)
import Shibuya.App (AppConfig (..), AppError (..), QueueProcessor (..), defaultAppConfig, mkBatchProcessor, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Batch (ackAll, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Error (ConfigError (..), PolicyError (..))
import Shibuya.Core.Ingested (Ingested, Message (..), mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec

spec :: Spec
spec = do
  describe "runApp" $ do
    it "rejects inboxSize 0 before starting processors" $ do
      result <- runEff $ runTracingNoop $ do
        messages <- createTestMessages 1
        let processor = mkProcessor (testAdapter messages) alwaysAckOk
        runApp defaultAppConfig {inboxSize = 0} [(ProcessorId "invalid-config", processor)]

      case result of
        Left (AppConfigInvalid (InvalidInboxSize 0)) -> pure ()
        Left err -> expectationFailure $ "Expected AppConfigInvalid, got: " ++ show err
        Right _ -> expectationFailure "Expected config validation to fail"

    it "rejects negative inboxSize before Natural conversion" $ do
      result <- runEff $ runTracingNoop $ do
        messages <- createTestMessages 1
        let processor = mkProcessor (testAdapter messages) alwaysAckOk
        runApp defaultAppConfig {inboxSize = -5} [(ProcessorId "invalid-config", processor)]

      case result of
        Left (AppConfigInvalid (InvalidInboxSize (-5))) -> pure ()
        Left err -> expectationFailure $ "Expected AppConfigInvalid, got: " ++ show err
        Right _ -> expectationFailure "Expected config validation to fail"

    describe "processor identity validation" $ do
      it "rejects duplicate ordinary processor IDs before adapter acquisition" $ do
        assertDuplicateRejected $ \adapter ->
          [ (ProcessorId "duplicate", mkProcessor adapter alwaysAckOk),
            (ProcessorId "duplicate", mkProcessor adapter alwaysAckOk)
          ]

      it "rejects duplicate batch processor IDs before adapter acquisition" $ do
        assertDuplicateRejected $ \adapter ->
          let batchHandler _ _ = pure (ackAll AckOk)
           in [ (ProcessorId "duplicate", mkBatchProcessor adapter batchHandler defaultBatchConfig),
                (ProcessorId "duplicate", mkBatchProcessor adapter batchHandler defaultBatchConfig)
              ]

      it "rejects duplicate mixed processor IDs before adapter acquisition" $ do
        assertDuplicateRejected $ \adapter ->
          let batchHandler _ _ = pure (ackAll AckOk)
           in [ (ProcessorId "duplicate", mkProcessor adapter alwaysAckOk),
                (ProcessorId "duplicate", mkBatchProcessor adapter batchHandler defaultBatchConfig)
              ]

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
            defaultAppConfig
            [ (ProcessorId "test", processor)
            ]

        case res of
          Left err -> pure $ Left err
          Right appHandle -> do
            waitApp appHandle
            -- Stop the supervisor and its children so they do not outlive this test.
            stopApp appHandle
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
            defaultAppConfig
            [ (ProcessorId "test", processor)
            ]

        case res of
          Left err -> do
            decs <- liftIO $ readIORef tracking.trackedDecisions
            pure (decs, Left err)
          Right appHandle -> do
            waitApp appHandle
            -- Stop the supervisor and its children so they do not outlive this test.
            stopApp appHandle
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
            defaultAppConfig
            [ (ProcessorId "proc1", proc1),
              (ProcessorId "proc2", proc2)
            ]

        case res of
          Left err -> pure $ Left err
          Right appHandle -> do
            waitApp appHandle
            -- Stop the supervisor and its children so they do not outlive this test.
            stopApp appHandle
            pure $ Right ()

      result `shouldBe` Right ()

  describe "Policy validation" $ do
    it "rejects nonpositive and overflowing concurrency before adapter acquisition" $ do
      let overflow = maxBound `div` 2 + 1
          batchHandler _ _ = pure (ackAll AckOk)
      assertPolicyRejected
        (InvalidConcurrency 0)
        (\adapter -> QueueProcessor adapter alwaysAckOk Unordered (Ahead 0))
      assertPolicyRejected
        (InvalidConcurrency (-1))
        (\adapter -> QueueProcessor adapter alwaysAckOk PartitionedInOrder (Async (-1)))
      assertPolicyRejected
        (InvalidConcurrency 0)
        (\adapter -> (mkBatchProcessor adapter batchHandler defaultBatchConfig) {concurrency = Async 0})
      assertPolicyRejected
        (ConcurrencyCapacityOverflow overflow)
        (\adapter -> QueueProcessor adapter alwaysAckOk Unordered (Async overflow))
      assertPolicyRejected
        (ConcurrencyCapacityOverflow overflow)
        (\adapter -> (mkBatchProcessor adapter batchHandler defaultBatchConfig) {concurrency = Ahead overflow})

    it "rejects StrictInOrder with Async" $ do
      result <- runEff $ runTracingNoop $ do
        messages <- createTestMessages 3
        let adapter = testAdapter messages
            handler = alwaysAckOk
            -- Invalid combination: StrictInOrder requires Serial
            processor = QueueProcessor adapter handler StrictInOrder (Async 5)

        runApp defaultAppConfig [(ProcessorId "invalid", processor)]

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

        runApp defaultAppConfig [(ProcessorId "invalid", processor)]

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
            defaultAppConfig
            [ (ProcessorId "async", proc1),
              (ProcessorId "ahead", proc2)
            ]
        case res of
          Left err -> pure $ Left err
          Right appHandle -> do
            waitApp appHandle
            -- Stop the supervisor and its children so they do not outlive this test.
            stopApp appHandle
            pure $ Right ()

      result `shouldBe` Right ()

  describe "mkProcessor" $ do
    it "creates processor with Unordered ordering" $ do
      messages <- runEff $ createTestMessages 1
      let adapter = testAdapter messages
          handler = alwaysAckOk
          ordering = case mkProcessor adapter handler of
            QueueProcessor {ordering = o} -> o
            BatchingProcessor {ordering = o} -> o
      ordering `shouldBe` Unordered

    it "creates processor with Serial concurrency" $ do
      messages <- runEff $ createTestMessages 1
      let adapter = testAdapter messages
          handler = alwaysAckOk
          concurrency = case mkProcessor adapter handler of
            QueueProcessor {concurrency = c} -> c
            BatchingProcessor {concurrency = c} -> c
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
            (mkEnvelope msgId ("message-" <> show i))
              { cursor = Just (CursorInt i),
                enqueuedAt = Just testTime
              }
          ackHandle = AckHandle $ \_ -> pure () -- No-op ack
      pure $ mkIngested env ackHandle

-- | Create N test messages with tracking acks
createTrackedMessages :: (IOE :> es) => TrackingAck -> Int -> Eff es [Ingested es String]
createTrackedMessages tracking n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId = MessageId $ "msg-" <> (if i < 10 then "0" else "") <> Text.pack (show i)
          env =
            (mkEnvelope msgId ("message-" <> show i))
              { cursor = Just (CursorInt i),
                enqueuedAt = Just testTime
              }
          ackHandle = trackingAckHandle tracking msgId
      pure $ mkIngested env ackHandle

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

assertDuplicateRejected ::
  (Adapter '[Tracing, IOE] String -> [(ProcessorId, QueueProcessor '[Tracing, IOE])]) ->
  Expectation
assertDuplicateRejected mkProcessors = do
  acquiredRef <- newIORef (0 :: Int)
  result <- runEff $ runTracingNoop $ do
    messages <- createTestMessages 1
    let adapter =
          (testAdapter messages)
            { source =
                Stream.mapM
                  (\msg -> liftIO (modifyIORef' acquiredRef (+ 1)) >> pure msg)
                  (Stream.fromList messages)
            }
    runApp defaultAppConfig (mkProcessors adapter)

  case result of
    Left (AppConfigInvalid (DuplicateProcessorId (ProcessorId "duplicate"))) -> pure ()
    Left err -> expectationFailure $ "Expected duplicate-ID config error, got: " ++ show err
    Right _ -> expectationFailure "Expected duplicate processor IDs to be rejected"
  readIORef acquiredRef `shouldReturn` 0

assertPolicyRejected ::
  PolicyError ->
  (Adapter '[Tracing, IOE] String -> QueueProcessor '[Tracing, IOE]) ->
  Expectation
assertPolicyRejected expectedError mkProcessorUnderTest = do
  acquiredRef <- newIORef (0 :: Int)
  result <- runEff $ runTracingNoop $ do
    messages <- createTestMessages 1
    let adapter =
          (testAdapter messages)
            { source =
                Stream.mapM
                  (\msg -> liftIO (modifyIORef' acquiredRef (+ 1)) >> pure msg)
                  (Stream.fromList messages)
            }
    runApp defaultAppConfig [(ProcessorId "invalid-policy", mkProcessorUnderTest adapter)]

  case result of
    Left (AppPolicyError actualError) -> actualError `shouldBe` expectedError
    Left err -> expectationFailure $ "Expected policy error, got: " ++ show err
    Right _ -> expectationFailure "Expected concurrency policy to be rejected"
  readIORef acquiredRef `shouldReturn` 0
