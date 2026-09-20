{-# LANGUAGE OverloadedStrings #-}

module Shibuya.App.LifecycleSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Concurrent.STM (readTVarIO)
import Control.Exception (SomeException, mask, try)
import Control.Monad (join, void)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (UTCTime (..), diffUTCTime, fromGregorian, getCurrentTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    QueueProcessor,
    ShutdownConfig (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    mkBatchProcessor,
    mkProcessor,
    runApp,
    stopAppGracefully,
    waitApp,
  )
import Shibuya.Batch (BatchConfig (..), ackAll, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..), ProcessorMetrics (..), ProcessorState (..), sampleMetrics)
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Internal.App (AppHandle (..))
import Shibuya.Internal.Runner.Master (startMaster, stopMaster)
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor (..), runSupervised)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
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
      sp <- runSupervised master 10 (ProcessorId "cancelled") Unordered Serial infiniteAdapter alwaysAckOk
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

  it "StopAllOnFailure delivers one processor failure to the caller exactly once" $ do
    result <- UIO.timeout 10_000_000 $ UIO.withAsync countLinkedDeliveries UIO.wait
    result `shouldBe` Just 1

  it "IgnoreFailures isolates a failing processor" $ do
    countBRef <- newIORef (0 :: Int)

    result <-
      UIO.timeout 5_000_000 $
        runEff $
          runTracingNoop $ do
            messagesB <- createTestMessages 20
            let handlerA _ = pure AckOk
                handlerB _ = do
                  liftIO $ threadDelay 10_000
                  liftIO $ modifyIORef' countBRef (+ 1)
                  pure AckOk
                procA = mkProcessor (failingAfterAdapter 3 "Adapter A source failed!") handlerA
                procB = mkProcessor (testAdapter messagesB) handlerB
            app <-
              runAppOrFail
                IgnoreFailures
                10
                [(ProcessorId "ignore-fail-A", procA), (ProcessorId "ignore-fail-B", procB)]
            waitApp app
            metricsA <- processorMetrics app (ProcessorId "ignore-fail-A")
            _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
            countB <- liftIO $ readIORef countBRef
            pure (metricsA, countB)

    case result of
      Nothing -> expectationFailure "IgnoreFailures run timed out"
      Just (metricsA, countB) -> do
        countB `shouldBe` 20
        case metricsA.state of
          Failed msg _ -> msg `shouldSatisfy` Text.isInfixOf "Adapter A source failed"
          other -> expectationFailure $ "Expected failed processor metrics, got: " ++ show other

runAppOrFail ::
  (IOE :> es, Tracing :> es) =>
  SupervisionStrategy ->
  Int ->
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (AppHandle es)
runAppOrFail strategy inboxSize processors = do
  result <- runApp defaultAppConfig {strategy = strategy, inboxSize = inboxSize} processors
  case result of
    Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err) >> error "unreachable"
    Right app -> pure app

-- | Run one failing processor under 'StopAllOnFailure' on the calling thread and
-- count the linked-thread exceptions that thread receives.
--
-- The deliveries are asynchronous exceptions, so one that lands between two
-- handlers escapes both. Everything therefore runs under 'mask' and waits only
-- inside 'restore', wrapped in base's 'try' (UnliftIO's deliberately ignores
-- asynchronous exceptions): none can arrive between iterations, and the count is
-- exact. The handle is retained until the end so garbage collection plays no part.
countLinkedDeliveries :: IO Int
countLinkedDeliveries =
  mask $ \restore -> do
    stopRef <- newIORef (pure ())
    started <-
      try @SomeException $
        restore $
          runEff $
            runTracingNoop $ do
              let failing = mkProcessor (failingAfterAdapter 0 "single-delivery failure") (\_ -> pure AckOk)
              app <- runAppOrFail StopAllOnFailure 10 [(ProcessorId "single-delivery", failing)]
              liftIO $
                writeIORef stopRef $
                  runEff $
                    runTracingNoop $
                      void (stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app)
    let countUntilQuiet :: Int -> IO Int
        countUntilQuiet n = do
          window <- try @SomeException (restore (threadDelay 300_000))
          case window of
            Left _ -> countUntilQuiet (n + 1)
            Right () -> pure n
    deliveries <- countUntilQuiet (either (const 1) (const 0) started)
    join (readIORef stopRef)
    pure deliveries

processorMetrics ::
  (IOE :> es) =>
  AppHandle es ->
  ProcessorId ->
  Eff es ProcessorMetrics
processorMetrics app pid =
  case app of
    AppHandle {processors = processorsMap} ->
      case Map.lookup pid processorsMap of
        Nothing -> liftIO $ expectationFailure ("missing processor: " <> show pid) >> error "unreachable"
        Just (SupervisedProcessor {metrics = metricsHandle}, _) -> liftIO $ sampleMetrics metricsHandle

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
        (mkEnvelope msgId ("message-" <> show i))
          { cursor = Just (CursorInt i),
            enqueuedAt = Just testTime
          }
  pure $ mkIngested env (AckHandle $ \_ -> pure ())

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
