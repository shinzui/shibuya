{-# LANGUAGE OverloadedStrings #-}

module Shibuya.App.LifecycleSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Concurrent.STM (readTVarIO)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), diffUTCTime, fromGregorian, getCurrentTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppHandle,
    QueueProcessor,
    ShutdownConfig (..),
    SupervisionStrategy (..),
    mkBatchProcessor,
    mkProcessor,
    runApp,
    stopAppGracefully,
    waitApp,
  )
import Shibuya.Batch (BatchConfig (..), ackAll, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Runner.Master (startMaster, stopMaster)
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Runner.Supervised (SupervisedProcessor (..), runSupervised)
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import UnliftIO qualified as UIO

spec :: Spec
spec = describe "Shibuya.App lifecycle" $ do
  it "waitApp returns after a handler halts" $ do
    result <-
      UIO.timeout 5_000_000 $
        runEff $
          runTracingNoop $ do
            messages <- createTestMessages 10
            let handler _ = pure $ AckHalt (HaltFatal "stop")
                processor = mkProcessor (testAdapter messages) handler
            app <- runAppOrFail IgnoreFailures 10 [(ProcessorId "halt", processor)]
            waitApp app
            _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
            pure ()

    result `shouldBe` Just ()

  it "stopAppGracefully returns True promptly after halt" $ do
    result <-
      UIO.timeout 5_000_000 $
        runEff $
          runTracingNoop $ do
            messages <- createTestMessages 10
            let handler _ = pure $ AckHalt (HaltFatal "stop")
                processor = mkProcessor (testAdapter messages) handler
            app <- runAppOrFail IgnoreFailures 10 [(ProcessorId "halt-stop", processor)]
            liftIO $ threadDelay 200_000
            startedAt <- liftIO getCurrentTime
            drained <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
            finishedAt <- liftIO getCurrentTime
            pure (drained, diffUTCTime finishedAt startedAt)

    case result of
      Just (drained, elapsed) -> do
        drained `shouldBe` True
        elapsed `shouldSatisfy` (< 2)
      Nothing -> expectationFailure "stopAppGracefully timed out"

  it "cancellation sets done" $ do
    doneAfterStop <- runEff $ runTracingNoop $ do
      master <- startMaster IgnoreAll
      sp <- runSupervised master 10 (ProcessorId "cancelled") Serial infiniteAdapter alwaysAckOk
      liftIO $ threadDelay 50_000
      stopMaster master
      liftIO $ readTVarIO sp.done

    doneAfterStop `shouldBe` True

  it "waitApp returns after a batch handler halts" $ do
    result <-
      UIO.timeout 5_000_000 $
        runEff $
          runTracingNoop $ do
            messages <- createTestMessages 10
            let handler _info _msgs = pure $ ackAll (AckHalt (HaltFatal "stop"))
                config = defaultBatchConfig {batchSize = 2, batchTimeout = 0.1}
                processor = mkBatchProcessor (testAdapter messages) handler config
            app <- runAppOrFail IgnoreFailures 10 [(ProcessorId "batch-halt", processor)]
            waitApp app
            _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
            pure ()

    result `shouldBe` Just ()

  it "graceful completion under StopAllOnFailure does not kill siblings" $ do
    countBRef <- newIORef (0 :: Int)

    result <-
      UIO.timeout 5_000_000 $
        runEff $
          runTracingNoop $ do
            messagesA <- createTestMessages 3
            messagesB <- createTestMessages 30
            let handlerA _ = pure AckOk
                handlerB _ = do
                  liftIO $ threadDelay 10_000
                  liftIO $ modifyIORef' countBRef (+ 1)
                  pure AckOk
                procA = mkProcessor (testAdapter messagesA) handlerA
                procB = mkProcessor (testAdapter messagesB) handlerB
            app <-
              runAppOrFail
                StopAllOnFailure
                10
                [(ProcessorId "complete-A", procA), (ProcessorId "complete-B", procB)]
            waitApp app
            _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
            liftIO $ readIORef countBRef

    result `shouldBe` Just 30

  it "halt under StopAllOnFailure does not kill siblings" $ do
    countARef <- newIORef (0 :: Int)
    countBRef <- newIORef (0 :: Int)

    result <-
      UIO.timeout 5_000_000 $
        runEff $
          runTracingNoop $ do
            messagesA <- createTestMessages 10
            messagesB <- createTestMessages 30
            let handlerA _ = do
                  count <- liftIO $ readIORef countARef
                  liftIO $ modifyIORef' countARef (+ 1)
                  if count >= 1
                    then pure $ AckHalt (HaltFatal "A stops")
                    else pure AckOk
                handlerB _ = do
                  liftIO $ threadDelay 10_000
                  liftIO $ modifyIORef' countBRef (+ 1)
                  pure AckOk
                procA = mkProcessor (testAdapter messagesA) handlerA
                procB = mkProcessor (testAdapter messagesB) handlerB
            app <-
              runAppOrFail
                StopAllOnFailure
                10
                [(ProcessorId "halt-A", procA), (ProcessorId "halt-B", procB)]
            waitApp app
            _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
            liftIO $ readIORef countBRef

    result `shouldBe` Just 30

  it "failure under StopAllOnFailure kills siblings and propagates" $ do
    countBRef <- newIORef (0 :: Int)

    result <-
      UIO.withAsync
        ( runEff $
            runTracingNoop $ do
              messagesB <- createTestMessages 50
              let handlerA _ = pure AckOk
                  handlerB _ = do
                    liftIO $ threadDelay 20_000
                    liftIO $ modifyIORef' countBRef (+ 1)
                    pure AckOk
                  procA = mkProcessor (failingAfterAdapter 3 "Adapter A source failed!") handlerA
                  procB = mkProcessor (testAdapter messagesB) handlerB
              app <-
                runAppOrFail
                  StopAllOnFailure
                  10
                  [(ProcessorId "fail-A", procA), (ProcessorId "fail-B", procB)]
              liftIO $ threadDelay 500_000
              _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
              pure ()
        )
        UIO.waitCatch

    case result of
      Left err ->
        Text.pack (show err) `shouldSatisfy` Text.isInfixOf "Adapter A source failed"
      Right () ->
        expectationFailure "Expected adapter A source failure to propagate"

    countB <- readIORef countBRef
    countB `shouldSatisfy` (< 50)

runAppOrFail ::
  (IOE :> es, Tracing :> es) =>
  SupervisionStrategy ->
  Int ->
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (AppHandle es)
runAppOrFail strategy inboxSize processors = do
  result <- runApp strategy inboxSize processors
  case result of
    Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err) >> error "unreachable"
    Right app -> pure app

alwaysAckOk :: (Applicative f) => a -> f AckDecision
alwaysAckOk _ = pure AckOk

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2024 1 1) 0

createTestMessages :: (IOE :> es) => Int -> Eff es [Ingested es String]
createTestMessages n = traverse createTestMessage [1 .. n]

createTestMessage :: (IOE :> es) => Int -> Eff es (Ingested es String)
createTestMessage i = do
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
  pure $
    Ingested
      { envelope = env,
        ack = AckHandle $ \_ -> pure (),
        lease = Nothing
      }

testAdapter :: [Ingested es String] -> Adapter es String
testAdapter messages =
  Adapter
    { adapterName = "test:list",
      source = Stream.fromList messages,
      shutdown = pure ()
    }

failingAfterAdapter :: (IOE :> es) => Int -> Text.Text -> Adapter es String
failingAfterAdapter goodCount failureText =
  Adapter
    { adapterName = "test:failing",
      source = Stream.unfoldrM step (0 :: Int),
      shutdown = pure ()
    }
  where
    step n
      | n < goodCount = do
          msg <- createTestMessage (n + 1)
          pure (Just (msg, n + 1))
      | otherwise = error (Text.unpack failureText)

infiniteAdapter :: (IOE :> es) => Adapter es String
infiniteAdapter =
  Adapter
    { adapterName = "test:infinite",
      source = Stream.unfoldrM step (1 :: Int),
      shutdown = pure ()
    }
  where
    step n = do
      liftIO $ threadDelay 5_000
      msg <- createTestMessage n
      pure (Just (msg, n + 1))
