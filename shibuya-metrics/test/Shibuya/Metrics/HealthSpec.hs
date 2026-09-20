module Shibuya.Metrics.HealthSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Concurrent.NQE.Supervisor (Strategy (IgnoreAll))
import Control.Exception (bracket, throwIO)
import Data.Atomics.Counter (readCounter)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Word (Word64)
import Effectful (runEff)
import Shibuya.App (Master)
import Shibuya.Core.Metrics
  ( AckDecisionMetric (CountProcessed),
    HotCounters (..),
    InFlightInfo (..),
    MetricsHandle (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    beginProcessing,
    finishProcessing,
    newMetricsHandle,
    newMetricsHandleWithClock,
    sampleMetrics,
  )
import Shibuya.Internal.Runner.Master
  ( markMasterDraining,
    markProcessorFailed,
    registerProcessor,
    startMaster,
    stopMaster,
    unregisterProcessor,
  )
import Shibuya.Metrics.Health
  ( ApplicationStatus (..),
    DependencyStatus (..),
    HealthConfig (..),
    LivenessStatus (..),
    ProcessorHealth (..),
    ReadinessStatus (..),
    checkDetailedHealth,
    checkLiveness,
    checkReadiness,
    defaultHealthConfig,
  )
import Shibuya.Metrics.TestSupport (registerFailedProcessor, withMaster)
import System.Timeout (timeout)
import Test.Hspec (Spec, around, describe, it, shouldBe)

spec :: Spec
spec = do
  around withMaster $ describe "health characterization" $ do
    it "reports a running, intentionally empty master live and ready" $ \master -> do
      checkLiveness defaultHealthConfig master `shouldReturn` LivenessStatus {alive = True}
      checkReadiness defaultHealthConfig master []
        `shouldReturn` ReadinessStatus
          { ready = True,
            application = ConfiguredEmpty,
            processors = ProcessorHealth {total = 0, healthy = 0, failed = 0, stuck = 0},
            dependencies = []
          }

    it "reports a failed processor while it remains registered" $ \master -> do
      _ <- registerFailedProcessor master (ProcessorId "failed")
      readiness <- checkReadiness defaultHealthConfig master []
      readiness.ready `shouldBe` False
      readiness.application `shouldBe` Running
      readiness.processors `shouldBe` ProcessorHealth {total = 1, healthy = 0, failed = 1, stuck = 0}

      (detailed, metrics) <- checkDetailedHealth defaultHealthConfig master []
      detailed `shouldBe` readiness
      length metrics `shouldBe` 1

    it "reports an unhealthy dependency unready with its diagnostic fields" $ \master -> do
      let dependency =
            DependencyStatus
              { name = "database",
                healthy = False,
                latencyMs = Just 7,
                errorMsg = Just "unavailable"
              }
      readiness <- checkReadiness defaultHealthConfig master [pure dependency]
      readiness.ready `shouldBe` False
      readiness.dependencies `shouldBe` [dependency]

    it "restamps separated bursts and reports progress independently" $ \master -> do
      now <- getCurrentTime
      clock <- newIORef 0
      handle <- newMetricsHandleWithClock (readIORef clock) (addUTCTime (-120) now)
      runEff $ registerProcessor master (ProcessorId "bursts") handle

      _ <- beginProcessing handle 1
      writeIORef clock (seconds 1)
      finishProcessing handle (Right CountProcessed)
      readIORef handle.stateActiveRef `shouldReturn` False

      writeIORef clock (seconds 119)
      _ <- beginProcessing handle 1
      metrics <- sampleMetrics handle
      case metrics.state of
        Processing (InFlightInfo 1 1) burstStarted lastProgress -> do
          burstStarted `shouldBe` lastProgress
          lastProgress `shouldBe` addUTCTime (-1) now
        other -> fail $ "expected processing metrics, got " <> show other

      readiness <- checkReadiness defaultHealthConfig master []
      readiness.ready `shouldBe` True

    it "keeps sustained concurrent progress ready after the burst threshold" $ \master -> do
      now <- getCurrentTime
      clock <- newIORef 0
      handle <- newMetricsHandleWithClock (readIORef clock) (addUTCTime (-120) now)
      runEff $ registerProcessor master (ProcessorId "sustained") handle

      _ <- beginProcessing handle 2
      writeIORef clock (seconds 10)
      _ <- beginProcessing handle 2
      writeIORef clock (seconds 30)
      finishProcessing handle (Right CountProcessed)
      writeIORef clock (seconds 119)
      _ <- beginProcessing handle 2

      readiness <- checkReadiness defaultHealthConfig master []
      readiness.ready `shouldBe` True
      readiness.processors.stuck `shouldBe` 0

    it "reports a genuinely non-progressing handler stuck" $ \master -> do
      now <- getCurrentTime
      clock <- newIORef 0
      handle <- newMetricsHandleWithClock (readIORef clock) (addUTCTime (-120) now)
      runEff $ registerProcessor master (ProcessorId "stuck") handle
      _ <- beginProcessing handle 1
      _ <- sampleMetrics handle
      writeIORef clock (seconds 120)

      readiness <- checkReadiness defaultHealthConfig master []
      readiness.ready `shouldBe` False
      readiness.processors.stuck `shouldBe` 1

    it "never lets duplicate completion drive in-flight below zero" $ \master -> do
      handle <- registerTestHandle master (ProcessorId "floor")
      _ <- beginProcessing handle 1
      finishProcessing handle (Right CountProcessed)
      finishProcessing handle (Right CountProcessed)
      readCounter handle.hot.inFlight `shouldReturn` 0

    it "retains a configured processor failure after metrics unregister" $ \master -> do
      _ <- registerTestHandle master (ProcessorId "failed-and-gone")
      runEff $ do
        markProcessorFailed master (ProcessorId "failed-and-gone") "boom" Nothing
        unregisterProcessor master (ProcessorId "failed-and-gone")
      readiness <- checkReadiness defaultHealthConfig master []
      readiness.ready `shouldBe` False
      readiness.application `shouldBe` ApplicationFailed
      readiness.processors `shouldBe` ProcessorHealth {total = 1, healthy = 0, failed = 1, stuck = 0}

    it "reports draining and stopped masters unavailable" $ \master -> do
      runEff $ markMasterDraining master
      draining <- checkReadiness defaultHealthConfig master []
      draining.ready `shouldBe` False
      draining.application `shouldBe` Draining

      runEff $ stopMaster master
      stopped <- checkReadiness defaultHealthConfig master []
      stopped.ready `shouldBe` False
      stopped.application `shouldBe` ApplicationStopped
      checkLiveness defaultHealthConfig master `shouldReturn` LivenessStatus {alive = False}

    it "bounds each hung dependency check" $ \master -> do
      let config = defaultHealthConfig {dependencyTimeoutMicros = 10_000}
      result <-
        timeout 100_000 $
          checkReadiness config master [threadDelay 5_000_000 >> pure healthyDependency]
      result `shouldSatisfy` isJust
      case result of
        Just readiness -> do
          readiness.ready `shouldBe` False
          readiness.dependencies
            `shouldBe` [DependencyStatus "unknown" False Nothing (Just "Dependency check timed out after 10000 microseconds")]
        Nothing -> fail "health check exceeded its dependency timeout"

    it "normalizes a synchronous dependency exception" $ \master -> do
      readiness <-
        checkReadiness defaultHealthConfig master [throwIO $ userError "database exploded"]
      readiness.ready `shouldBe` False
      readiness.dependencies
        `shouldBe` [DependencyStatus "unknown" False Nothing (Just "user error (database exploded)")]

    it "preserves asynchronous cancellation of a dependency check" $ \master -> do
      started <- newEmptyMVar
      worker <- async $ checkReadiness defaultHealthConfig master [putMVar started () >> threadDelay 5_000_000 >> pure healthyDependency]
      takeMVar started
      cancel worker
      waitCatch worker >>= (`shouldSatisfy` isLeft)

    it "keeps repeated master stop observable and idempotent" $ \master -> do
      runEff $ stopMaster master
      runEff $ stopMaster master
      checkLiveness defaultHealthConfig master `shouldReturn` LivenessStatus {alive = False}
      readiness <- checkReadiness defaultHealthConfig master []
      readiness.application `shouldBe` ApplicationStopped
      readiness.ready `shouldBe` False

  describe "starting health" $
    it "distinguishes a starting master from a configured-empty running master" $
      bracket
        (runEff $ startMaster IgnoreAll)
        (\master -> runEff $ stopMaster master)
        ( \master -> do
            readiness <- checkReadiness defaultHealthConfig master []
            readiness.ready `shouldBe` False
            readiness.application `shouldBe` Starting
        )

shouldReturn :: (Eq a, Show a) => IO a -> a -> IO ()
shouldReturn action expected = action >>= (`shouldBe` expected)

registerTestHandle :: Master -> ProcessorId -> IO MetricsHandle
registerTestHandle master pid = do
  now <- getCurrentTime
  handle <- newMetricsHandle now
  runEff $ registerProcessor master pid handle
  pure handle

seconds :: Word64 -> Word64
seconds value = value * 1_000_000_000

healthyDependency :: DependencyStatus
healthyDependency = DependencyStatus "hung" True Nothing Nothing

shouldSatisfy :: (Show a) => a -> (a -> Bool) -> IO ()
shouldSatisfy actual predicate =
  if predicate actual then pure () else fail $ "predicate failed for " <> show actual
